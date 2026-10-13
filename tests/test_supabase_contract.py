import io, json, tempfile, threading, unittest, urllib.request, urllib.error, http.cookiejar
from pathlib import Path
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from server import cloud, storage
from server.app import Handler, ATTEMPTS

REAL_CLOUD_CALL = cloud.call


class SupabaseContract(unittest.TestCase):
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
		ATTEMPTS.clear()
		self.user = {
			"id": "11111111-1111-4111-8111-111111111111",
			"email": "sam@example.com",
			"user_metadata": {"username": "samuel"},
		}
		self.remote = {
			"user": self.user,
			"access_token": "old-access",
			"refresh_token": "old-refresh",
		}
		self.calls = []
		self.rows = {}
		p = patch.object(cloud, "call", side_effect=self.provider)
		p.start()
		self.addCleanup(p.stop)
		self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
		self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
		self.thread.start()
		self.addCleanup(self.close)
		self.jar = http.cookiejar.CookieJar()
		self.client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

	def close(self):
		self.server.shutdown()
		self.server.server_close()
		self.thread.join()

	def provider(self, path, data=None, method=None, **kwargs):
		self.calls.append((path, data, method, kwargs))
		if path.startswith("/rest/v1/w8g_profiles"):
			return [{"email": self.user["email"]}]
		if path.startswith("/auth/v1/token"):
			return dict(self.remote)
		if path.startswith("/auth/v1/signup"):
			self.assertIn("redirect_to=", path)
			return {"user": self.user}  # Email confirmation required.
		if path == "/auth/v1/user":
			return self.user
		if path.startswith("/auth/v1/logout"):
			return {}
		if path.startswith("/rest/v1/w8g_records"):
			if method == "DELETE":
				self.rows.clear()
				return {}
			if data:
				self.rows[data["id"]] = data
				return {}
			return list(self.rows.values())
		raise AssertionError(path)

	def request(self, path, data=None):
		r = urllib.request.Request(
			f"http://127.0.0.1:{self.server.server_port}/api/" + path,
			data=None if data is None else json.dumps(data).encode(),
			headers={"Content-Type": "application/json"},
		)
		try:
			with self.client.open(r) as response:
				return response.status, json.load(response)
		except urllib.error.HTTPError as e:
			return e.code, json.load(e)

	def login(self):
		status, body = self.request(
			"login", {"login": "sam@example.com", "password": "test-password"}
		)
		self.assertEqual(status, 200)
		self.assertEqual(body["user"]["id"], self.user["id"])
		self.assertNotIn("access_token", body)

	def test_cookie_client_cloud_crud_and_logout(self):
		self.login()
		self.assertTrue(next(iter(self.jar)).has_nonstandard_attr("HttpOnly"))
		self.assertEqual(
			self.request(
				"records",
				{"id": "saved-a", "kind": "saved", "user_id": "attacker", "payload": {"stops": []}},
			)[0],
			200,
		)
		row = self.request("records")[1][0]
		self.assertEqual(row["user_id"], self.user["id"])
		writes = [c for c in self.calls if c[0].startswith("/rest/v1/w8g_records") and c[1]]
		self.assertEqual(writes[0][3]["token"], "old-access")
		self.assertFalse(writes[0][3].get("admin"))
		self.assertEqual(
			self.request("records", {"id": "saved-a", "kind": "saved", "delete": True})[0], 200
		)
		self.assertEqual(self.request("records")[1], [])
		self.request("logout", {})
		self.assertEqual(self.request("records")[0], 401)

	def test_username_lookup_server_only(self):
		with patch.object(cloud, "SECRET", "server-secret"):
			self.assertEqual(
				self.request("login", {"login": "samuel", "password": "test-password"})[0], 200
			)
		self.assertTrue(self.calls[0][3]["admin"])
		self.assertEqual(self.calls[1][1]["email"], "sam@example.com")

	def test_signup_waits_for_email_confirmation(self):
		status, body = self.request(
			"signup",
			{"username": "samuel", "email": "sam@example.com", "password": "test-password"},
		)
		self.assertEqual(status, 200)
		self.assertIn("confirm", body["message"])
		self.assertEqual(len(self.jar), 0)

	def test_mobile_server_does_not_serve_prototype(self):
		base = f"http://127.0.0.1:{self.server.server_port}"
		with self.client.open(base + "/") as r:
			text = r.read().decode()
			self.assertIn("Confirmation not completed here", text)
			self.assertNotIn("App/app.js", text)
			self.assertEqual(r.headers["Cache-Control"], "no-store")
		with self.assertRaises(urllib.error.HTTPError) as error:
			self.client.open(base + "/index.html")
		self.assertEqual(error.exception.code, 404)
		self.assertEqual(self.request("recovery-session", {"access_token": "old-access"})[0], 410)

	def test_mobile_recovery_http_contract(self):
		from urllib.parse import urlparse, parse_qs

		original = self.provider
		self.user["email_confirmed_at"] = "2026-09-28"

		def provider(path, *args, **kwargs):
			if path.startswith("/auth/v1/recover?"):
				self.calls.append((path, args[0], None, kwargs))
				return {}
			return original(path, *args, **kwargs)

		with patch.object(cloud, "call", side_effect=provider):
			status, body = self.request("recover", {"email": self.user["email"]})
			self.assertEqual(status, 200)
			ticket = body["requestToken"]
			self.assertNotIn("access_token", body)
			redirect = parse_qs(urlparse(self.calls[0][0]).query)["redirect_to"][0]
			url = (
				f"http://127.0.0.1:{self.server.server_port}"
				+ urlparse(redirect).path
				+ "?code=provider-code"
			)
			with self.client.open(url) as r:
				text = r.read().decode()
				self.assertIn("Reset approved", text)
				self.assertIsNone(r.headers.get("Set-Cookie"))
				self.assertEqual(r.headers["Referrer-Policy"], "no-referrer")
				self.assertNotIn("approval=", text)
			self.assertEqual(
				self.request("recovery/status", {"requestToken": ticket}),
				(200, {"state": "confirmed"}),
			)
			self.assertEqual(
				self.request(
					"recovery/finish",
					{"requestToken": ticket, "password": "new-test-password"},
				)[0],
				200,
			)
			self.assertEqual(len(self.jar), 0)

	def test_refresh_updates_server_session(self):
		self.login()
		original = self.provider

		def expired(path, *args, **kwargs):
			if path == "/auth/v1/user" and kwargs.get("token") == "old-access":
				raise cloud.CloudError("Expired", 401)
			if "grant_type=refresh_token" in path:
				return {**self.remote, "access_token": "new-access", "refresh_token": "new-refresh"}
			return original(path, *args, **kwargs)

		with patch.object(cloud, "call", side_effect=expired):
			self.assertEqual(self.request("session")[0], 200)
		token = next(iter(self.jar)).value
		remote = json.loads(storage.get_session(token)["remote"])
		self.assertEqual(remote["refresh_token"], "new-refresh")

	def test_outage_preserves_session_without_refresh(self):
		self.login()
		token = next(iter(self.jar)).value
		with patch.object(cloud, "call", side_effect=cloud.CloudError("Unavailable", 503)) as call:
			self.assertEqual(self.request("session")[0], 503)
			self.assertEqual(call.call_count, 1)
		self.assertIsNotNone(storage.get_session(token))
		self.assertEqual(self.request("session")[0], 200)

	def test_identity_mismatch_invalidates_session(self):
		self.login()
		with patch.object(cloud, "call", return_value={**self.user, "id": "another-user"}):
			self.assertEqual(self.request("records")[0], 401)
		self.assertEqual(self.request("session")[1], {"user": None})

	def test_transport_outage_is_typed_and_redacted(self):
		with (
			patch.object(cloud, "URL", "https://example.supabase.co"),
			patch.object(cloud, "urlopen", side_effect=urllib.error.URLError("private details")),
		):
			with self.assertRaises(cloud.CloudError) as error:
				REAL_CLOUD_CALL("/auth/v1/user", token="secret")
		self.assertEqual(error.exception.status, 503)
		self.assertNotIn("private details", str(error.exception))


if __name__ == "__main__":
	unittest.main()
