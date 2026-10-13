"""Phone-owned email confirmations. Browsers never receive an app login session."""

import base64
import hashlib
import html
import os
import re
import secrets
import threading
import time
from urllib.parse import urlencode, urlparse
from . import cloud, storage

LOCKS = [threading.Lock() for _ in range(64)]
LIFETIME = 30 * 60


def init():
	with storage.db() as c:
		c.execute("""CREATE TABLE IF NOT EXISTS email_flows (
			id TEXT PRIMARY KEY, ticket_hash TEXT NOT NULL UNIQUE,
			kind TEXT NOT NULL, email TEXT NOT NULL, verifier TEXT,
			state TEXT NOT NULL, expires REAL NOT NULL,
			access_token TEXT, user_id TEXT, approval_hash TEXT, attempts INTEGER DEFAULT 0
		)""")
		c.execute("DELETE FROM email_flows WHERE expires < ?", (time.time(),))


def base_url():
	value = os.getenv("W8G_AUTH_BASE_URL", "http://MacBook-Pro.local:8787").rstrip("/")
	parts = urlparse(value)
	if (
		parts.scheme not in ("http", "https")
		or not parts.netloc
		or parts.path
		or parts.query
		or parts.fragment
		or parts.username
	):
		raise ValueError("W8G_AUTH_BASE_URL must be a server origin without a path.")
	if (
		parts.scheme != "https"
		and parts.hostname not in ("localhost", "127.0.0.1")
		and not (parts.hostname or "").endswith(".local")
	):
		raise ValueError("Use HTTPS for a public authentication server.")
	return value


def start(kind, data):
	if not cloud.ENABLED:
		raise ValueError("Supabase must be configured for email confirmation.")
	email = str(data.get("email", "")).strip()
	if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
		raise ValueError("Enter a valid email address.")
	if kind not in ("signup", "recovery"):
		raise ValueError("Unknown email flow.")
	if kind == "signup":
		storage.valid(data["username"], email, data["password"])
	init()
	flow_id, ticket, verifier = (secrets.token_urlsafe(32) for _ in range(3))
	challenge = (
		base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
	)
	redirect = base_url() + "/auth/callback/" + flow_id
	body = {"email": email, "code_challenge": challenge, "code_challenge_method": "s256"}
	if kind == "signup":
		body.update(password=data["password"], data={"username": data["username"]})
	expires = time.time() + LIFETIME
	with storage.db() as c:
		c.execute(
			"INSERT INTO email_flows VALUES(?,?,?,?,?,?,?,?,?,?,?)",
			(
				flow_id,
				hashlib.sha256(ticket.encode()).hexdigest(),
				kind,
				email.casefold(),
				verifier,
				"pending",
				expires,
				None,
				None,
				None,
				0,
			),
		)
	try:
		result = cloud.call(
			("/auth/v1/signup" if kind == "signup" else "/auth/v1/recover")
			+ "?"
			+ urlencode({"redirect_to": redirect}),
			body,
		)
		# Do not silently bypass the configured confirmation requirement.
		if result.get("access_token"):
			raise ValueError("Enable Confirm email in Supabase before using this signup flow.")
	except Exception:
		with storage.db() as c:
			c.execute("DELETE FROM email_flows WHERE id=?", (flow_id,))
		raise
	message = "Check your email to confirm your account, then sign in on your iPhone."
	if kind == "recovery":
		message = "If this address is registered, a recovery email has been requested. Confirm the link, then return to this screen."
	return {"message": message, "requestToken": ticket, "expiresAt": expires}


def confirm(flow_id, code):
	"""Exchange a one-use code with the server-held PKCE verifier."""
	if not re.fullmatch(r"[A-Za-z0-9_-]{43}", flow_id) or not code or len(code) > 2048:
		raise ValueError("Invalid confirmation link.")
	with LOCKS[hash(flow_id) % len(LOCKS)]:
		with storage.db() as c:
			r = c.execute(
				"SELECT * FROM email_flows WHERE id=? AND expires>?", (flow_id, time.time())
			).fetchone()
		if not r or r["state"] != "pending" or not r["verifier"]:
			raise ValueError("This link has expired or was already used.")
		remote = cloud.call(
			"/auth/v1/token?grant_type=pkce",
			{
				"auth_code": code,
				"code_verifier": r["verifier"],
			},
		)
		# Validate with Auth; never trust an email supplied by the browser or client.
		u = cloud.call("/auth/v1/user", token=remote["access_token"])
		if (u.get("email") or "").casefold() != r["email"] or not u.get("email_confirmed_at"):
			raise PermissionError("Confirmation does not match this request.")
		access = remote["access_token"] if r["kind"] == "recovery" else None
		with storage.db() as c:
			c.execute(
				"UPDATE email_flows SET state='confirmed', verifier=NULL, access_token=?, user_id=?, approval_hash=? WHERE id=?",
				(access, u["id"], None, flow_id),
			)
		if r["kind"] == "signup":
			# Confirmation is not a browser or app login.
			try:
				cloud.call("/auth/v1/logout?scope=local", {}, token=remote["access_token"])
			except cloud.CloudError:
				pass
		return r["kind"]


def owned_request(ticket, allow_expired=False):
	if not isinstance(ticket, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", ticket):
		raise PermissionError("Request expired. Request a new email from this iPhone.")
	with storage.db() as c:
		r = c.execute(
			"SELECT * FROM email_flows WHERE ticket_hash=?",
			(hashlib.sha256(ticket.encode()).hexdigest(),),
		).fetchone()
	if not r or (not allow_expired and r["expires"] <= time.time()):
		raise PermissionError("Request expired. Request a new email from this iPhone.")
	return r


def status(ticket):
	"""Only the requesting app's secret ticket can read approval state."""
	r = owned_request(ticket, allow_expired=True)
	if r["kind"] != "recovery":
		raise PermissionError("This is not a password-reset request.")
	state = r["state"] if r["expires"] > time.time() else "expired"
	return {"state": state}


def finish(ticket, password):
	r = owned_request(ticket)
	with LOCKS[hash(r["id"]) % len(LOCKS)]:
		r = owned_request(ticket)
		if r["kind"] != "recovery" or r["state"] != "confirmed" or not r["access_token"]:
			raise PermissionError("Confirm the recovery email before changing your password.")
		if not isinstance(password, str) or not 8 <= len(password) <= 200:
			raise ValueError("Use a password of 8–200 characters.")
		u = cloud.call("/auth/v1/user", token=r["access_token"])
		if u["id"] != r["user_id"] or (u.get("email") or "").casefold() != r["email"]:
			raise PermissionError("Recovery identity changed. Request a new email.")
		cloud.call("/auth/v1/user", {"password": password}, "PUT", token=r["access_token"])
		with storage.db() as c:
			c.execute(
				"UPDATE email_flows SET state='used', access_token=NULL, verifier=NULL, approval_hash=NULL WHERE email=? AND kind='recovery'",
				(r["email"],),
			)
			c.execute("DELETE FROM sessions WHERE user_id=?", (r["user_id"],))
		try:
			cloud.call("/auth/v1/logout?scope=global", {}, token=r["access_token"])
		except cloud.CloudError:
			pass
		return {"message": "Password updated. Sign in with your new password."}


def page(result):
	"""A receipt only: no login, route UI, password form, or provider credentials."""
	content = {
		"signup": (
			"Email confirmed",
			"Your email is confirmed. Sign in to w8g on your iPhone.",
			"w8g://auth/confirmed",
		),
		"recovery": (
			"Reset approved",
			"The reset request is approved. Return to the Reset password screen in w8g. It will detect this approval and let you choose your new password.",
			"w8g://auth/reset",
		),
		"error": (
			"Link unavailable",
			"This link could not be completed. Return to w8g on your iPhone and request a new email.",
			"",
		),
		"home": (
			"Confirmation not completed here",
			"This address is not a valid email confirmation callback. If your email brought you here, check the server callback address in Supabase, then request a new email from w8g.",
			"",
		),
	}
	title, message, target = content.get(result, content["error"])
	nonce = secrets.token_urlsafe(24)
	link = f'<p><a href="{target}">Return to w8g on iPhone</a> (optional)</p>' if target else ""
	# Remove the consumed provider code from browser history without navigating away.
	script = f"<script nonce='{nonce}'>history.replaceState(null,'','/auth/result');</script>"
	raw = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
	<meta name="viewport" content="width=device-width,initial-scale=1"><title>w8g · {html.escape(title)}</title>
	<style nonce="{nonce}">body{{font:17px/1.6 system-ui;background:#f7f7f4;color:#242621;margin:60px auto;padding:24px;max-width:520px}}a{{color:inherit}}h1{{line-height:1.2}}</style></head>
	<body><p>w8g</p><h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>{link}<p>You can close this tab.</p>{script}</body></html>'''.encode()
	return (
		raw,
		f"default-src 'none'; style-src 'nonce-{nonce}'; script-src 'nonce-{nonce}'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
	)
