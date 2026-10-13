import sqlite3, json, time, secrets, hashlib, hmac, re
from pathlib import Path

DB = Path(__file__).resolve().parents[1] / "data/app/app.sqlite3"


def db():
	c = sqlite3.connect(DB, timeout=30)
	c.row_factory = sqlite3.Row
	return c


def init():
	DB.parent.mkdir(parents=True, exist_ok=True)
	with db() as c:
		c.executescript("""CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,username TEXT UNIQUE COLLATE NOCASE,email TEXT UNIQUE COLLATE NOCASE,salt TEXT,password TEXT);
CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY,user_id TEXT,expires REAL,remote TEXT);
CREATE TABLE IF NOT EXISTS records(user_id TEXT,id TEXT,kind TEXT,payload TEXT,updated REAL,PRIMARY KEY(user_id,id));
CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,user_id TEXT,key TEXT,state TEXT,payload TEXT,result TEXT,error TEXT,progress TEXT,created REAL,UNIQUE(user_id,key));
CREATE TABLE IF NOT EXISTS cloud_outbox(user_id TEXT,id TEXT,payload TEXT,PRIMARY KEY(user_id,id));
CREATE TABLE IF NOT EXISTS drafts(id TEXT PRIMARY KEY,user_id TEXT,payload TEXT,revision INTEGER,confirmed INTEGER DEFAULT 0);""")
		c.execute(
			"UPDATE jobs SET state='failed',error='Server restarted. Please submit this route again.' WHERE state IN ('queued','running')"
		)


def digest(password, salt):
	return hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 310000).hex()


def valid(username, email, password):
	if not re.fullmatch(r"[\w.-]{3,32}", username):
		raise ValueError("Username needs 3–32 letters, numbers, dots or underscores.")
	if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
		raise ValueError("Enter a valid email.")
	if len(password) < 8 or len(password) > 200:
		raise ValueError("Use a password of 8–200 characters.")


def signup(d):
	valid(d["username"], d["email"], d["password"])
	uid = secrets.token_hex(16)
	salt = secrets.token_hex(16)
	with db() as c:
		c.execute(
			"INSERT INTO users VALUES(?,?,?,?,?)",
			(uid, d["username"], d["email"], salt, digest(d["password"], salt)),
		)
	return dict(id=uid, username=d["username"], email=d["email"])


def login(d):
	with db() as c:
		r = c.execute(
			"SELECT * FROM users WHERE username=? OR email=?", (d["login"], d["login"])
		).fetchone()
	actual = digest(d["password"], r["salt"] if r else "0" * 32)
	if not r or not hmac.compare_digest(actual, r["password"]):
		raise PermissionError("Incorrect username/email or password.")
	return dict(id=r["id"], username=r["username"], email=r["email"])


def session(user, remote=None):
	t = secrets.token_urlsafe(32)
	with db() as c:
		c.execute(
			"INSERT INTO sessions VALUES(?,?,?,?)",
			(
				hashlib.sha256(t.encode()).hexdigest(),
				user["id"],
				time.time() + 7 * 86400,
				json.dumps(remote) if remote else None,
			),
		)
	return t


def get_session(t):
	with db() as c:
		r = c.execute(
			"SELECT s.*,u.username,u.email FROM sessions s LEFT JOIN users u ON s.user_id=u.id WHERE token=? AND expires>?",
			(hashlib.sha256(t.encode()).hexdigest(), time.time()),
		).fetchone()
	return dict(r) if r else None


def logout(t):
	with db() as c:
		c.execute("DELETE FROM sessions WHERE token=?", (hashlib.sha256(t.encode()).hexdigest(),))


def profile(uid, d):
	with db() as c:
		u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
		name = d.get("username", u["username"])
		valid(name, u["email"], d.get("password") or "12345678")
		c.execute("UPDATE users SET username=? WHERE id=?", (name, uid))
		if d.get("password"):
			if not hmac.compare_digest(
				digest(d.get("currentPassword", ""), u["salt"]), u["password"]
			):
				raise ValueError("Current password is incorrect.")
			c.execute(
				"UPDATE users SET password=? WHERE id=?", (digest(d["password"], u["salt"]), uid)
			)
	return dict(id=uid, username=name, email=u["email"])
