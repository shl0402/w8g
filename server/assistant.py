"""Shared Gemini intent endpoint for web and future native clients."""

import json, os, re, threading, time, urllib.request, urllib.error
from .network import urlopen

SCHEMA = {
	"type": "object",
	"properties": {
		"intent": {"type": "string", "enum": ["route", "place", "arrivals", "unsupported"]},
		"places": {"type": "array", "items": {"type": "string"}, "maxItems": 10},
		"order": {"type": "string", "enum": ["ordered", "optimise"]},
		"reply": {"type": "string"},
	},
	"required": ["intent", "places", "order", "reply"],
}
INSTRUCTION = "You are w8g, a Hong Kong journey assistant. Extract intent and place names only. Supported tasks: place finding, 1-to-1 routes, ordered or optimised multi-stop routes, transit arrivals. Decline unrelated requests politely. Never invent coordinates, routes or arrival times. Preserve stop order unless asked to optimise. The user must resolve and confirm locations before any routing request. Reply briefly in English or Traditional Chinese, matching the user. Use the supplied JSON schema."
_LOCK = threading.Lock()
_REQUESTS = {}
_ACTIVE = set()


class AIError(Exception):
	def __init__(self, message, status=502):
		super().__init__(message)
		self.status = status


def configured():
	return bool(os.getenv("GEMINI_API_KEY", "").strip())


def model():
	return os.getenv("GEMINI_MODEL", "gemini-3.1-pro-preview")


def interpret(text, messages=None):
	key = os.getenv("GEMINI_API_KEY", "").strip()
	if not key:
		raise AIError(
			"Shared AI is not configured yet. Add a server Gemini key or use your own key in Settings.",
			503,
		)
	if not isinstance(text, str) or not text.strip() or len(text) > 3000:
		raise ValueError("Enter a message of 1–3000 characters.")
	if not re.fullmatch(r"[a-zA-Z0-9._-]+", model()):
		raise AIError("The server Gemini model setting is invalid.", 503)
	context = []
	if messages is not None and not isinstance(messages, list):
		raise ValueError("Invalid conversation history.")
	for m in (messages or [])[-8:]:
		if (
			isinstance(m, dict)
			and m.get("role") in ("user", "assistant")
			and isinstance(m.get("text"), str)
			and m["text"].strip()
		):
			context.append(
				{
					"role": "user" if m["role"] == "user" else "model",
					"parts": [{"text": m["text"][:3000]}],
				}
			)
	payload = {
		"systemInstruction": {"parts": [{"text": INSTRUCTION}]},
		"contents": context + [{"role": "user", "parts": [{"text": text}]}],
		"generationConfig": {"responseMimeType": "application/json", "responseJsonSchema": SCHEMA},
	}
	req = urllib.request.Request(
		f"https://generativelanguage.googleapis.com/v1beta/models/{model()}:generateContent",
		data=json.dumps(payload).encode(),
		headers={"Content-Type": "application/json", "x-goog-api-key": key},
	)
	try:
		with urlopen(req, timeout=90) as response:
			data = json.load(response)
	except urllib.error.HTTPError as e:
		# Never relay provider bodies: they can contain credential or request details.
		if e.code == 429:
			raise AIError("AI usage limit reached. Please try again later.", 429) from None
		if e.code in (400, 401, 403, 404):
			raise AIError(
				"Shared AI could not authenticate or access its configured model. Check the server Gemini settings.",
				503,
			) from None
		raise AIError("Gemini is temporarily unavailable. Please try again.", 502) from None
	except Exception:
		raise AIError("Could not reach Gemini. Please try again.", 502) from None
	try:
		parts = data["candidates"][0]["content"]["parts"]
		raw = "".join(
			p["text"] for p in parts if isinstance(p.get("text"), str) and not p.get("thought")
		)
		out = json.loads(raw)
		if (
			out.get("intent") not in SCHEMA["properties"]["intent"]["enum"]
			or not isinstance(out.get("places"), list)
			or not isinstance(out.get("reply"), str)
			or out.get("order") not in ("ordered", "optimise")
		):
			raise ValueError()
		if len(out["places"]) > 10 or any(not isinstance(p, str) for p in out["places"]):
			raise ValueError()
		return dict(
			intent=out["intent"],
			places=[p[:200] for p in out["places"]],
			order=out["order"],
			reply=out["reply"][:2000],
			engine="Gemini · shared server",
			model=model(),
		)
	except Exception:
		raise AIError(
			"Gemini returned an unreadable planning response. Please try again.", 502
		) from None


def chat(uid, text, messages=None):
	now = time.monotonic()
	with _LOCK:
		for key in list(_REQUESTS):
			_REQUESTS[key] = [t for t in _REQUESTS[key] if t > now - 60]
			if not _REQUESTS[key]:
				del _REQUESTS[key]
		recent = _REQUESTS.get(uid, [])
		if uid in _ACTIVE:
			raise AIError("Your previous AI message is still processing.", 429)
		if len(recent) >= 10:
			raise AIError("Please wait a moment before sending another AI message.", 429)
		if len(_ACTIVE) >= 8:
			raise AIError("AI is busy. Please try again shortly.", 429)
		_REQUESTS[uid] = recent + [now]
		_ACTIVE.add(uid)
	try:
		return interpret(text, messages)
	finally:
		with _LOCK:
			_ACTIVE.discard(uid)
