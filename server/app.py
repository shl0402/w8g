import argparse, os, sys, json, time, secrets, sqlite3, mimetypes, subprocess, threading
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie
from urllib.parse import urlparse, parse_qs
from . import storage, cloud, routing, assistant, arrivals, email_flow

ROOT = Path(__file__).resolve().parents[1]
ATTEMPTS = {}
LOCK = threading.Lock()
# Bounded lock stripes prevent two simultaneous requests rotating the same refresh token.
SESSION_LOCKS = [threading.Lock() for _ in range(64)]


class Handler(BaseHTTPRequestHandler):
	def log_message(self, *args):
		pass  # Don't log search terms, keys or account credentials.

	def send(self, data, status=200, cookie=None):
		raw = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
		self.send_response(status)
		self.send_header("Content-Type", "application/json; charset=utf-8")
		self.send_header("Cache-Control", "no-store")
		self.send_header("X-Content-Type-Options", "nosniff")
		self.send_header("Content-Length", str(len(raw)))
		if cookie:
			self.send_header("Set-Cookie", cookie)
		self.end_headers()
		self.wfile.write(raw)

	def confirmation_page(self, result):
		raw, policy = email_flow.page(result)
		self.send_response(200)
		self.send_header("Content-Type", "text/html; charset=utf-8")
		self.send_header("Cache-Control", "no-store")
		self.send_header("Referrer-Policy", "no-referrer")
		self.send_header("Content-Security-Policy", policy)
		self.send_header("X-Content-Type-Options", "nosniff")
		self.send_header("Content-Length", str(len(raw)))
		self.end_headers()
		self.wfile.write(raw)

	def token(self):
		c = SimpleCookie()
		c.load(self.headers.get("Cookie", ""))
		return c["w8g"].value if "w8g" in c else ""

	def account(self, required=True):
		token = self.token()
		with SESSION_LOCKS[hash(token) % len(SESSION_LOCKS)]:
			s = storage.get_session(token)
			if s and bool(s.get("remote")) != cloud.ENABLED:
				storage.logout(token)
				s = None
			if s and s.get("remote"):
				r = json.loads(s["remote"])
				try:
					u = cloud.user(cloud.call("/auth/v1/user", token=r["access_token"]))
				except cloud.CloudError as e:
					# Supabase returns 403 bad_jwt for expired access tokens.
					# Other forbidden responses and outages must not rotate credentials.
					if not (e.status == 401 or (e.status == 403 and e.code == "bad_jwt")):
						raise
					try:
						r = cloud.call(
							"/auth/v1/token?grant_type=refresh_token",
							{"refresh_token": r["refresh_token"]},
						)
						u = cloud.user(r["user"])
					except cloud.CloudError as refresh_error:
						if refresh_error.status not in (400, 401, 403):
							raise
						storage.logout(token)
						raise PermissionError("Session expired. Please sign in again.") from None
					if u["id"] != s["user_id"]:
						storage.logout(token)
						raise PermissionError("Session changed. Please sign in again.")
					with storage.db() as c:
						c.execute(
							"UPDATE sessions SET remote=? WHERE token=?",
							(json.dumps(r), s["token"]),
						)
				if u["id"] != s["user_id"]:
					storage.logout(token)
					raise PermissionError("Session changed. Please sign in again.")
				s.update(user=u, remote=r)
				return s
			if s:
				s["user"] = dict(id=s["user_id"], username=s["username"], email=s["email"])
				return s
			if required:
				raise PermissionError("Sign in to search, plan routes or use online services.")

	def do_GET(self):
		try:
			url = urlparse(self.path)
			path = url.path
			q = parse_qs(url.query)
			if path.startswith("/auth/callback/"):
				try:
					kind = email_flow.confirm(path.rsplit("/", 1)[-1], q.get("code", [""])[0])
				except (ValueError, PermissionError, KeyError):
					return self.confirmation_page("error")
				return self.confirmation_page(kind)
			if path in ("/", "/auth/result"):
				return self.confirmation_page("home")
			if path == "/api/status":
				try:
					routing.router.graphql("{__typename}", timeout=2)
					ready = True
				except Exception:
					ready = False
				return self.send(
					dict(
						ready=ready,
						auth="Supabase" if cloud.ENABLED else "Local prototype accounts",
						ai="Gemini · shared server"
						if assistant.configured()
						else "Gemini · session key required",
						supabaseConfigured=cloud.ENABLED,
						serverGeminiConfigured=assistant.configured(),
						geminiModel=assistant.model(),
						usernameLoginConfigured=not cloud.ENABLED or bool(cloud.SECRET),
						minDate=routing.router.service_window()[0].isoformat(),
						maxDate=routing.router.service_window()[1].isoformat(),
						stations=[dict(name=s[0], code=s[2], line=s[1]) for s in arrivals.STATIONS],
					)
				)
			if path == "/api/session":
				s = self.account(False)
				return self.send({"user": s["user"] if s else None})
			if path.startswith("/api/"):
				s = self.account()
				uid = s["user_id"]
				if path.startswith("/api/indoor/"):
					try:
						return self.send(routing.router.indoor_data(path))
					except (KeyError, FileNotFoundError):
						return self.send({"error": "Indoor dataset not found"}, 404)
				if path == "/api/places":
					return self.send(routing.router.search(q.get("q", [""])[0][:150]))
				if path == "/api/records":
					if cloud.ENABLED:
						cloud.flush_history(uid, s["remote"]["access_token"])
						rows = cloud.call(
							"/rest/v1/w8g_records?user_id=eq."
							+ uid
							+ "&select=id,kind,payload,updated&order=updated.desc",
							token=s["remote"]["access_token"],
						)
					else:
						with storage.db() as c:
							rows = [
								dict(r)
								for r in c.execute(
									"SELECT id,kind,payload,updated FROM records WHERE user_id=? ORDER BY updated DESC LIMIT 100",
									(uid,),
								)
							]
						for r in rows:
							r["payload"] = json.loads(r["payload"])
					return self.send(rows)
				if path == "/api/jobs":
					with storage.db() as c:
						ids = [
							r[0]
							for r in c.execute(
								"SELECT id FROM jobs WHERE user_id=? ORDER BY created DESC LIMIT 15",
								(uid,),
							)
						]
					return self.send([routing.job(uid, j) for j in ids])
				if path.startswith("/api/jobs/"):
					return self.send(routing.job(uid, path.split("/")[-1]))
				return self.send({"error": "Not found"}, 404)
			return self.send(
				{"error": "This server is for the iPhone app. No web app is served."}, 404
			)
		except cloud.CloudError as e:
			self.send(
				{"error": str(e)}, 503 if e.status >= 500 else 401 if e.status == 401 else 400
			)
		except PermissionError as e:
			self.send({"error": str(e)}, 401)
		except KeyError:
			self.send({"error": "Not found"}, 404)
		except Exception as e:
			self.send({"error": str(e)}, 400)

	def do_POST(self):
		try:
			origin = self.headers.get("Origin")
			if origin and urlparse(origin).netloc != self.headers.get("Host"):
				raise PermissionError("Cross-origin request rejected.")
			if not self.headers.get("Content-Type", "").startswith("application/json"):
				raise ValueError("JSON required")
			n = int(self.headers.get("Content-Length", "0"))
			if not 0 < n < 2_000_000:
				raise ValueError("Request too large")
			d = json.loads(self.rfile.read(n))
			path = urlparse(self.path).path
			if not isinstance(d, dict):
				raise ValueError("JSON object required")
			# Google credentials have no place in the app-server or database contract.
			if any(k.lower() in ("googlekey", "googleapikey", "apikey") for k in d):
				raise ValueError("Google keys must remain in browser session storage.")
			if path == "/api/recovery-session":
				return self.send({"error": "Use the phone-owned password-reset flow."}, 410)
			if path == "/api/recovery/status":
				return self.send(email_flow.status(d.get("requestToken")))
			if path == "/api/recovery/finish":
				return self.send(email_flow.finish(d.get("requestToken"), d.get("password")))
			if path in ("/api/login", "/api/signup", "/api/recover"):
				with LOCK:
					now = time.time()
					key = self.client_address[0]
					recent = [x for x in ATTEMPTS.get(key, []) if x > now - 60]
					if len(recent) >= 15:
						raise ValueError("Too many attempts. Please wait one minute.")
					ATTEMPTS[key] = recent + [now]
				if path == "/api/recover":
					return self.send(email_flow.start("recovery", d))
				if path == "/api/signup" and cloud.ENABLED:
					return self.send(email_flow.start("signup", d))
				if cloud.ENABLED:
					if path.endswith("signup"):
						storage.valid(d["username"], d["email"], d["password"])
						u, r = cloud.signup(d)
					else:
						u, r = cloud.login(d)
					if not u:
						return self.send(
							{"message": "Check your email to confirm your account, then sign in."}
						)
				else:
					u = storage.signup(d) if path.endswith("signup") else storage.login(d)
					r = None
				t = storage.session(u, r)
				return self.send(
					{"user": u},
					cookie=f"w8g={t}; HttpOnly; SameSite=Strict; Path=/; Max-Age=604800",
				)
			if path == "/api/logout":
				try:
					current = self.account(False)
				except (PermissionError, cloud.CloudError):
					current = None
				if current and current.get("remote"):
					try:
						cloud.call(
							"/auth/v1/logout?scope=local",
							{},
							token=current["remote"]["access_token"],
						)
					except Exception:
						pass
				storage.logout(self.token())
				return self.send(
					{"ok": True}, cookie="w8g=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"
				)
			s = self.account()
			uid = s["user_id"]
			if path == "/api/profile":
				if cloud.ENABLED:
					storage.valid(
						d.get("username") or s["user"]["username"],
						s["user"]["email"],
						d.get("password") or "12345678",
					)
					body = {}
					if d.get("username"):
						body["data"] = {"username": d["username"]}
					if d.get("password"):
						body["password"] = d["password"]
						if d.get("currentPassword"):
							body["current_password"] = d["currentPassword"]
					u = cloud.user(
						cloud.call("/auth/v1/user", body, "PUT", token=s["remote"]["access_token"])
					)
				else:
					u = storage.profile(uid, d)
				return self.send({"user": u})
			if path == "/api/records":
				if d.get("kind") not in ("saved", "history"):
					raise ValueError("Invalid record kind")
				rid = str(d["id"])[:100]
				import re

				if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", rid):
					raise ValueError("Invalid record ID")
				if cloud.ENABLED:
					token = s["remote"]["access_token"]
					if d.get("delete"):
						cloud.call(
							"/rest/v1/w8g_records?user_id=eq." + uid + "&id=eq." + rid,
							method="DELETE",
							token=token,
						)
					else:
						cloud.put_record(uid, rid, d["kind"], d["payload"], token)
				else:
					with storage.db() as c:
						if d.get("delete"):
							c.execute("DELETE FROM records WHERE id=? AND user_id=?", (rid, uid))
						else:
							c.execute(
								"INSERT OR REPLACE INTO records VALUES(?,?,?,?,?)",
								(uid, rid, d["kind"], json.dumps(d["payload"]), time.time()),
							)
				return self.send({"ok": True})
			if path == "/api/ai":
				return self.send(assistant.chat(uid, d.get("text"), d.get("messages")))
			if path == "/api/arrivals":
				return self.send(arrivals.arrivals(d))
			if path == "/api/drafts":
				clean = routing.validate(d)
				ident = secrets.token_hex(16)
				with storage.db() as c:
					c.execute(
						"INSERT INTO drafts VALUES(?,?,?,?,0)", (ident, uid, json.dumps(clean), 1)
					)
				return self.send({"id": ident, "revision": 1})
			if path == "/api/jobs":
				if d.get("ai"):
					with storage.db() as c:
						draft = c.execute(
							"SELECT * FROM drafts WHERE id=? AND user_id=?", (d.get("draftId"), uid)
						).fetchone()
						if (
							not draft
							or d.get("revision") != draft["revision"]
							or d.get("confirmed") is not True
						):
							raise ValueError("Confirm the current stop card before planning.")
						clean = json.loads(draft["payload"])
						clean["channel"] = "ai"
						clean["key"] = "draft:" + draft["id"]
						result = routing.start(uid, clean)
						c.execute("UPDATE drafts SET confirmed=1 WHERE id=?", (draft["id"],))
				else:
					result = routing.start(uid, d)
				return self.send(result, 202)
			return self.send({"error": "Not found"}, 404)
		except cloud.CloudError as e:
			self.send(
				{"error": str(e)}, 503 if e.status >= 500 else 401 if e.status == 401 else 400
			)
		except PermissionError as e:
			self.send({"error": str(e)}, 401)
		except assistant.AIError as e:
			self.send({"error": str(e)}, e.status)
		except sqlite3.IntegrityError:
			self.send({"error": "That username or email is already used."}, 409)
		except (ValueError, KeyError, TypeError) as e:
			self.send({"error": str(e)}, 400)
		except Exception as e:
			self.send({"error": str(e)}, 502)


def main():
	p = argparse.ArgumentParser()
	p.add_argument("--port", type=int, default=8787)
	p.add_argument("--otp-port", type=int, default=8092)
	p.add_argument("--no-otp", action="store_true")
	a = p.parse_args()
	storage.init()
	email_flow.init()
	routing.init(a.otp_port)
	child = None
	log = None
	if not a.no_otp:
		try:
			routing.router.graphql("{__typename}", timeout=2)
		except Exception:
			log = (ROOT / "data/app/otp.log").open("a")
			child = subprocess.Popen(
				[
					"java",
					"-Xmx8G",
					"-jar",
					str(ROOT / "data/user_inputs/otp/otp-shaded-2.9.0.jar"),
					"--load",
					"--serve",
					"--bindAddress",
					"127.0.0.1",
					"--port",
					str(a.otp_port),
					str(ROOT / "data/generated/otp-smoke"),
				],
				stdout=log,
				stderr=subprocess.STDOUT,
			)
	print(f"w8g: http://localhost:{a.port} — routing engine loads in the background", flush=True)
	try:
		ThreadingHTTPServer(
			(os.environ.get("W8G_HOST", "127.0.0.1"), a.port), Handler
		).serve_forever()
	except KeyboardInterrupt:
		pass
	finally:
		if child:
			child.terminate()
			child.wait(timeout=15)
		if log:
			log.close()


if __name__ == "__main__":
	main()
