"""Regression tests for Supabase's actual 403 bad_jwt expiry response.

Uses an isolated database and mocked upstream; never reads real credentials.
"""
import io
import json
import tempfile
import unittest
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from server import cloud, storage
from server.app import Handler

REAL_CALL = cloud.call


class SessionRefresh(unittest.TestCase):
	def setUp(self):
		tmp = tempfile.TemporaryDirectory()
		self.addCleanup(tmp.cleanup)
		for p in (patch.object(storage, "DB", Path(tmp.name) / "app.sqlite3"),
				patch.object(cloud, "ENABLED", True)):
			p.start()
			self.addCleanup(p.stop)
		storage.init()
		self.user = {"id": "test-user", "email": "test@example.com"}
		self.remote = {"user": self.user, "access_token": "old-access", "refresh_token": "old-refresh"}
		self.token = storage.session(cloud.user(self.user), self.remote)

	def account(self):
		handler = object.__new__(Handler)
		handler.headers = {"Cookie": "w8g=" + self.token}
		return handler.account()

	def provider(self, path, data=None, **kwargs):
		if path == "/auth/v1/user":
			if kwargs["token"] == "old-access":
				# Includes the HTTP decoding layer, not only a manually constructed error.
				error = urllib.error.HTTPError("https://example.invalid", 403, "Forbidden", {},
					io.BytesIO(b'{"code":403,"error_code":"bad_jwt","msg":"token is expired"}'))
				with patch.object(cloud, "urlopen", side_effect=error), patch.object(cloud, "URL", "https://example.invalid"):
					return REAL_CALL(path, token="old-access")
			self.assertEqual(kwargs["token"], "new-access")
			return self.user
		self.assertEqual(path, "/auth/v1/token?grant_type=refresh_token")
		self.assertEqual(data, {"refresh_token": "old-refresh"})
		return {**self.remote, "access_token": "new-access", "refresh_token": "new-refresh"}

	def test_actual_403_refreshes_and_survives_restart(self):
		with patch.object(cloud, "call", side_effect=self.provider) as call:
			self.assertEqual(self.account()["user"]["id"], self.user["id"])
			stored = json.loads(storage.get_session(self.token)["remote"])
			self.assertEqual(stored["refresh_token"], "new-refresh")
			# init is run on every server start. A new handler reads the persisted pair.
			storage.init()
			self.assertEqual(self.account()["user"]["id"], self.user["id"])
			self.assertEqual(sum("grant_type=refresh_token" in c.args[0] for c in call.call_args_list), 1)

	def test_concurrent_expired_requests_rotate_only_once(self):
		with patch.object(cloud, "call", side_effect=self.provider) as call:
			with ThreadPoolExecutor(max_workers=6) as pool:
				results = list(pool.map(lambda _: self.account(), range(6)))
			self.assertTrue(all(r["user"]["id"] == self.user["id"] for r in results))
			self.assertEqual(sum("grant_type=refresh_token" in c.args[0] for c in call.call_args_list), 1)

	def test_other_forbidden_errors_do_not_refresh_or_delete(self):
		with patch.object(cloud, "call", side_effect=cloud.CloudError("Forbidden", 403, "insufficient_aal")) as call:
			with self.assertRaises(cloud.CloudError):
				self.account()
			self.assertEqual(call.call_count, 1)
		self.assertIsNotNone(storage.get_session(self.token))

	def test_network_failure_preserves_session(self):
		with patch.object(cloud, "call", side_effect=cloud.CloudError("Unavailable", 503)):
			with self.assertRaises(cloud.CloudError):
				self.account()
		self.assertIsNotNone(storage.get_session(self.token))

	def test_refresh_outage_or_rate_limit_preserves_credentials(self):
		for status in (503, 429):
			with self.subTest(status=status):
				with patch.object(cloud, "call", side_effect=[
					cloud.CloudError("Expired", 403, "bad_jwt"), cloud.CloudError("Retry later", status)
				]):
					with self.assertRaises(cloud.CloudError):
						self.account()
				self.assertEqual(json.loads(storage.get_session(self.token)["remote"]), self.remote)

	def test_revoked_refresh_token_still_requires_login(self):
		with patch.object(cloud, "call", side_effect=[
			cloud.CloudError("Expired", 403, "bad_jwt"),
			cloud.CloudError("Revoked", 400, "refresh_token_not_found")
		]):
			with self.assertRaises(PermissionError):
				self.account()
		self.assertIsNone(storage.get_session(self.token))

	def test_refreshed_identity_must_match(self):
		with patch.object(cloud, "call", side_effect=[
			cloud.CloudError("Expired", 403, "bad_jwt"),
			{**self.remote, "user": {**self.user, "id": "someone-else"}}
		]):
			with self.assertRaises(PermissionError):
				self.account()
		self.assertIsNone(storage.get_session(self.token))


if __name__ == "__main__":
	unittest.main()
