from .network import urlopen

"""Optional Supabase adapter. All secrets and tokens stay on the app server."""
import os, json, urllib.request, urllib.parse, urllib.error, time

URL = os.getenv("SUPABASE_URL", "").rstrip("/")
KEY = os.getenv("SUPABASE_PUBLISHABLE_KEY", "")
SECRET = os.getenv("SUPABASE_SERVICE_KEY", "")
ENABLED = bool(URL and KEY)


class CloudError(ValueError):
	def __init__(self, message, status, code=None):
		super().__init__(message)
		self.status = status
		self.code = code


def call(path, data=None, method=None, token=None, admin=False, prefer=None):
	headers = {"apikey": SECRET if admin else KEY, "Content-Type": "application/json"}
	if token or admin and not SECRET.startswith("sb_secret_"):
		headers["Authorization"] = "Bearer " + (SECRET if admin else token)
	if prefer:
		headers["Prefer"] = prefer
	req = urllib.request.Request(
		URL + path,
		data=json.dumps(data).encode() if data is not None else None,
		headers=headers,
		method=method,
	)
	try:
		with urlopen(req, timeout=20) as r:
			return json.loads(r.read() or b"{}")
	except urllib.error.HTTPError as e:
		try:
			detail = json.loads(e.read() or b"{}")
		except (ValueError, UnicodeError):
			detail = {}
		message = (
			(detail.get("msg") or detail.get("message") or detail.get("error_description"))
			if isinstance(detail, dict)
			else None
		)
		if e.code >= 500:
			message = "Cloud service is temporarily unavailable. Please try again."
		code = detail.get("error_code") or detail.get("code") if isinstance(detail, dict) else None
		raise CloudError(message or "Cloud request failed", e.code, code) from None
	except (urllib.error.URLError, TimeoutError):
		raise CloudError("Cannot reach the cloud service. Please try again.", 503) from None


def signup(d):
	path = "/auth/v1/signup"

	if d.get("client") == "ios":
		path += "?" + urllib.parse.urlencode({
			"redirect_to": "w8g://auth/confirmed"
		})

	r = call(
		path,
		dict(
			email=d["email"],
			password=d["password"],
			data={"username": d["username"]},
		),
	)

	if not r.get("access_token"):
		return None, None

	return user(r["user"]), r


def user(u):
	return dict(
		id=u["id"],
		email=u.get("email", ""),
		username=u.get("user_metadata", {}).get("username") or u.get("email", "").split("@")[0],
	)


def login(d):
	email = d["login"]
	if "@" not in email:
		if not SECRET:
			raise ValueError(
				"Username login needs the private Supabase lookup key. Use your email for now."
			)
		rows = call(
			"/rest/v1/w8g_profiles?username=eq."
			+ urllib.parse.quote(email, safe="")
			+ "&select=email",
			admin=True,
		)
		if not rows:
			raise PermissionError("Incorrect username/email or password.")
		email = rows[0]["email"]
	r = call("/auth/v1/token?grant_type=password", dict(email=email, password=d["password"]))
	return user(r["user"]), r


def put_record(uid, rid, kind, payload, token):
	return call(
		"/rest/v1/w8g_records?on_conflict=user_id,id",
		dict(user_id=uid, id=rid, kind=kind, payload=payload, updated=time.time()),
		token=token,
		prefer="resolution=merge-duplicates,return=minimal",
	)


def flush_history(uid, token):
	# Completed jobs survive a closed browser. Retry cloud writes at the next sync.
	from . import storage

	with storage.db() as c:
		rows = c.execute("SELECT id,payload FROM cloud_outbox WHERE user_id=?", (uid,)).fetchall()
	for row in rows:
		put_record(uid, row["id"], "history", json.loads(row["payload"]), token)
		with storage.db() as c:
			c.execute("DELETE FROM cloud_outbox WHERE user_id=? AND id=?", (uid, row["id"]))
