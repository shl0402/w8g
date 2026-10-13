import io, json, os, tempfile, threading, unittest, urllib.request, urllib.error
from pathlib import Path
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from server import assistant, cloud, storage
from server.app import Handler


class CloudServices(unittest.TestCase):
	def setUp(self):
		self.tmp = tempfile.TemporaryDirectory()
		self.dbpatch = patch.object(storage, "DB", Path(self.tmp.name) / "test.db")
		self.dbpatch.start()
		storage.init()
		self.env = patch.dict(
			os.environ,
			{"GEMINI_API_KEY": "test-server-secret", "GEMINI_MODEL": "gemini-3.1-pro-preview"},
		)
		self.env.start()

	def tearDown(self):
		self.env.stop()
		self.dbpatch.stop()
		self.tmp.cleanup()

	def reply(self):
		return io.BytesIO(
			json.dumps(
				{
					"candidates": [
						{
							"content": {
								"parts": [
									{
										"text": json.dumps(
											{
												"intent": "route",
												"places": ["Central", "Mong Kok"],
												"order": "ordered",
												"reply": "Confirm the two locations.",
											}
										)
									}
								]
							}
						}
					]
				}
			).encode()
		)

	def test_provider_contract(self):
		with patch.object(assistant, "urlopen", return_value=self.reply()) as send:
			out = assistant.interpret("Central to Mong Kok", [{"role": "user", "text": "Hello"}])
		request = send.call_args.args[0]
		self.assertEqual(request.get_header("X-goog-api-key"), "test-server-secret")
		payload = json.loads(request.data)
		self.assertIn("responseJsonSchema", payload["generationConfig"])
		self.assertEqual(out["intent"], "route")
		self.assertNotIn("test-server-secret", json.dumps(out))
		self.assertNotIn("key=", request.full_url)

	def test_no_parser_fallback(self):
		with (
			patch.dict(os.environ, {"GEMINI_API_KEY": ""}),
			self.assertRaises(assistant.AIError) as err,
		):
			assistant.interpret("Central to Mong Kok")
		self.assertEqual(err.exception.status, 503)

	def test_provider_error_redaction(self):
		error = urllib.error.HTTPError(
			"https://example.invalid", 403, "Forbidden", {}, io.BytesIO(b"test-server-secret")
		)
		with (
			patch.object(assistant, "urlopen", side_effect=error),
			self.assertRaises(assistant.AIError) as err,
		):
			assistant.interpret("Central to Mong Kok")
		self.assertNotIn("test-server-secret", str(err.exception))

	def test_atomic_upsert_uses_user_token(self):
		with (
			patch.object(cloud, "URL", "https://example.supabase.co"),
			patch.object(cloud, "KEY", "test-publishable"),
			patch.object(cloud, "urlopen", return_value=io.BytesIO(b"")) as send,
		):
			cloud.put_record("user-a", "route-a", "saved", {"stops": []}, "user-token")
		req = send.call_args.args[0]
		self.assertEqual(req.get_method(), "POST")
		self.assertEqual(req.get_header("Authorization"), "Bearer user-token")
		self.assertEqual(req.get_header("Prefer"), "resolution=merge-duplicates,return=minimal")
		self.assertEqual(json.loads(req.data)["user_id"], "user-a")

	def test_history_retry_is_owned(self):
		with storage.db() as c:
			c.executemany(
				"INSERT INTO cloud_outbox VALUES(?,?,?)",
				[("a", "job-a", "{}"), ("b", "job-b", "{}")],
			)
		with patch.object(cloud, "put_record", side_effect=ValueError("network")):
			with self.assertRaises(ValueError):
				cloud.flush_history("a", "a-token")
		with storage.db() as c:
			self.assertEqual(c.execute("SELECT count(*) FROM cloud_outbox").fetchone()[0], 2)
		with patch.object(cloud, "put_record") as put:
			cloud.flush_history("a", "a-token")
		self.assertEqual(put.call_args.args[0], "a")
		with storage.db() as c:
			self.assertEqual(c.execute("SELECT user_id FROM cloud_outbox").fetchone()[0], "b")

	def test_authenticated_shared_endpoint_and_provider_switch(self):
		user = storage.signup(
			{"username": "testuser", "email": "test@example.com", "password": "test-password-123"}
		)
		token = storage.session(user)
		server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
		thread = threading.Thread(target=server.serve_forever, daemon=True)
		thread.start()
		url = f"http://127.0.0.1:{server.server_port}/api/ai"

		def request(cookie=False):
			return urllib.request.Request(
				url,
				data=json.dumps({"text": "Central to Mong Kok"}).encode(),
				headers={
					"Content-Type": "application/json",
					**({"Cookie": "w8g=" + token} if cookie else {}),
				},
			)

		try:
			with (
				patch.object(cloud, "ENABLED", False),
				patch.object(assistant, "urlopen", return_value=self.reply()) as upstream,
			):
				with self.assertRaises(urllib.error.HTTPError) as err:
					urllib.request.urlopen(request())
				self.assertEqual(err.exception.code, 401)
				upstream.assert_not_called()
				with urllib.request.urlopen(request(True)) as response:
					out = json.load(response)
				self.assertEqual(out["intent"], "route")
				self.assertNotIn("test-server-secret", json.dumps(out))
			with patch.object(cloud, "ENABLED", True), patch.object(assistant, "chat") as chat:
				with self.assertRaises(urllib.error.HTTPError) as err:
					urllib.request.urlopen(request(True))
				self.assertEqual(err.exception.code, 401)
				chat.assert_not_called()
		finally:
			server.shutdown()
			server.server_close()
			thread.join()


if __name__ == "__main__":
	unittest.main()
