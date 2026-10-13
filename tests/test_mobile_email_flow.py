import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlparse, parse_qs
from server import email_flow, cloud, storage


class MobileEmailFlow(unittest.TestCase):
	def setUp(self):
		self.tmp = tempfile.TemporaryDirectory()
		self.addCleanup(self.tmp.cleanup)
		p = patch.object(storage, "DB", Path(self.tmp.name) / "test.db")
		p.start()
		self.addCleanup(p.stop)
		storage.init()
		p = patch.object(cloud, "ENABLED", True)
		p.start()
		self.addCleanup(p.stop)
		self.email = "sam@example.com"
		self.user = {
			"id": "user-a",
			"email": self.email,
			"email_confirmed_at": "2026-09-28",
			"user_metadata": {"username": "sam"},
		}
		self.calls = []
		p = patch.object(cloud, "call", side_effect=self.provider)
		p.start()
		self.addCleanup(p.stop)

	def provider(self, path, data=None, method=None, **kwargs):
		self.calls.append((path, data, method, kwargs))
		if path.startswith(("/auth/v1/recover?", "/auth/v1/signup?")):
			self.callback = parse_qs(urlparse(path).query)["redirect_to"][0]
			self.challenge = data["code_challenge"]
			return {}
		if path == "/auth/v1/token?grant_type=pkce":
			import base64

			self.assertEqual(
				base64.urlsafe_b64encode(hashlib.sha256(data["code_verifier"].encode()).digest())
				.decode()
				.rstrip("="),
				self.challenge,
			)
			return {"access_token": "private-test-access", "user": self.user}
		if path == "/auth/v1/user":
			return self.user
		if path.startswith("/auth/v1/logout"):
			return {}
		raise AssertionError(path)

	def start(self, kind="recovery"):
		result = email_flow.start(
			kind, {"email": self.email, "username": "sam", "password": "initial-test-password"}
		)
		return result["requestToken"], self.callback.rsplit("/", 1)[-1]

	def test_cross_device_approval_is_detected_by_requesting_phone(self):
		ticket, fid = self.start()
		self.assertEqual(email_flow.status(ticket), {"state": "pending"})
		with self.assertRaises(PermissionError):
			email_flow.finish(ticket, "new-test-password")
		self.assertEqual(email_flow.confirm(fid, "provider-code"), "recovery")
		with self.assertRaises(PermissionError):
			email_flow.status("x" * 43)
		self.assertEqual(email_flow.status(ticket), {"state": "confirmed"})
		with self.assertRaises(ValueError):
			email_flow.finish(ticket, "short")
		self.assertIn("Password updated", email_flow.finish(ticket, "new-test-password")["message"])
		self.assertEqual(email_flow.status(ticket), {"state": "used"})
		with self.assertRaises(PermissionError):
			email_flow.finish(ticket, "another-password")
		with storage.db() as c:
			r = c.execute("SELECT * FROM email_flows WHERE id=?", (fid,)).fetchone()
			self.assertIsNone(r["access_token"])
			self.assertIsNone(r["verifier"])
		self.assertEqual(
			sum(path == "/auth/v1/user" and method == "PUT" for path, _, method, _ in self.calls), 1
		)

	def test_signup_confirms_without_browser_session(self):
		ticket, fid = self.start("signup")
		self.assertEqual(email_flow.confirm(fid, "provider-code"), "signup")
		with self.assertRaises(PermissionError):
			email_flow.status(ticket)
		with storage.db() as c:
			self.assertEqual(c.execute("SELECT count(*) FROM sessions").fetchone()[0], 0)
			self.assertIsNone(c.execute("SELECT access_token FROM email_flows").fetchone()[0])

	def test_wrong_identity_cannot_confirm(self):
		ticket, fid = self.start()
		self.user = {**self.user, "email": "someone-else@example.com"}
		with self.assertRaises(PermissionError):
			email_flow.confirm(fid, "provider-code")
		with storage.db() as c:
			self.assertEqual(c.execute("SELECT state FROM email_flows").fetchone()[0], "pending")

	def test_expiry_blocks_approval_and_password_change(self):
		ticket, fid = self.start()
		with storage.db() as c:
			c.execute("UPDATE email_flows SET expires=0")
		self.assertEqual(email_flow.status(ticket), {"state": "expired"})
		with self.assertRaises(ValueError):
			email_flow.confirm(fid, "provider-code")
		with self.assertRaises(PermissionError):
			email_flow.finish(ticket, "new-test-password")

	def test_bad_provider_code_or_receipt_visit_cannot_approve(self):
		ticket, fid = self.start()
		email_flow.page("home")
		self.assertEqual(email_flow.status(ticket), {"state": "pending"})
		with patch.object(cloud, "call", side_effect=cloud.CloudError("Invalid code", 400)):
			with self.assertRaises(cloud.CloudError):
				email_flow.confirm(fid, "invalid-code")
		self.assertEqual(email_flow.status(ticket), {"state": "pending"})

	def test_provider_error_removes_pending_request(self):
		with patch.object(
			cloud, "call", side_effect=cloud.CloudError("Email rate limit exceeded", 429)
		):
			with self.assertRaises(cloud.CloudError):
				self.start()
		with storage.db() as c:
			self.assertEqual(c.execute("SELECT count(*) FROM email_flows").fetchone()[0], 0)

	def test_receipt_contains_no_prototype_or_provider_credentials(self):
		raw, csp = email_flow.page("recovery")
		text = raw.decode()
		self.assertIn("w8g://auth/reset", text)
		self.assertIn("Reset password screen", text)
		for forbidden in (
			"access_token",
			"refresh_token",
			"App/app.js",
			"templates/",
			"<form",
			"approval=",
			"navigator.userAgent",
			"location.href",
			"confirmation code",
		):
			self.assertNotIn(forbidden, text)
		self.assertIn("default-src 'none'", csp)

	def test_request_ticket_not_in_link_and_token_not_in_status(self):
		ticket, fid = self.start()
		self.assertNotIn(ticket, self.callback)
		self.assertIn("/auth/callback/", self.callback)
		email_flow.confirm(fid, "provider-code")
		self.assertEqual(set(email_flow.status(ticket)), {"state"})
		with self.assertRaises(ValueError):
			email_flow.confirm(fid, "provider-code")


if __name__ == "__main__":
	unittest.main()
