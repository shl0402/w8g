#!/usr/bin/env python3
"""Standalone Gemini diagnosis. Python 3 only; no packages or w8g server needed."""
import getpass
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# Optional: paste your key between these quotes, then remove it after testing.
# Leaving this empty prompts securely in Terminal (recommended).
API_KEY = ""
DEFAULT_MODEL = "gemini-3.5-flash-lite"
BASE = "https://generativelanguage.googleapis.com/v1beta/"


class NoRedirect(urllib.request.HTTPRedirectHandler):
	def redirect_request(self, req, fp, code, msg, headers, newurl):
		return None


def request(key, path, body=None):
	payload = None if body is None else json.dumps(body).encode()
	req = urllib.request.Request(BASE + path, data=payload, headers={
		"x-goog-api-key": key, "Content-Type": "application/json"})
	try:
		with urllib.request.build_opener(NoRedirect()).open(req, timeout=45) as response:
			status, raw = response.status, response.read().decode()
	except urllib.error.HTTPError as error:
		status, raw = error.code, error.read().decode(errors="replace")
	except (urllib.error.URLError, TimeoutError, OSError) as error:
		print("Network/TLS error:", str(error).replace(key, "[REDACTED]"))
		return None, {}
	try:
		data = json.loads(raw)
	except ValueError:
		data = {"rawResponse": raw[:4000]}
	print("HTTP", status)
	if status != 200:
		print(json.dumps(data, ensure_ascii=False, indent=2).replace(key, "[REDACTED]"))
		hints = {
			400: "Read the message: malformed/unsupported parameters, key or regional/billing restrictions can cause this.",
			401: "Authentication rejected. Check the exact key and authentication requirements.",
			403: "Access denied. Check key restrictions, API/project access and the exact error reason.",
			404: "Check the model name and API version against the available models below.",
			429: "Quota/rate limit exhausted. Check the named quota and project billing; billing alone may not increase it immediately.",
			503: "Temporary service unavailability. Retry later."}
		print(hints.get(status, "Use the error status, message and details above to diagnose this response."))
	return status, data


def generate(key, model, config):
	status, data = request(key, "models/" + model + ":generateContent", {
		"contents": [{"role": "user", "parts": [{"text": "Reply with OK only."}]}],
		"generationConfig": config})
	if status == 200:
		texts = [p.get("text", "") for c in data.get("candidates", [])
			for p in c.get("content", {}).get("parts", []) if not p.get("thought")]
		print("Reply:", " ".join(texts) or "[No visible text]")
		print("Finish reasons:", [c.get("finishReason") for c in data.get("candidates", [])])
		print("Usage:", data.get("usageMetadata", {}))
		if data.get("promptFeedback"):
			print("Prompt feedback:", data["promptFeedback"])
	return status


def main():
	key = API_KEY.strip()
	if not key:
		if not sys.stdin.isatty():
			raise SystemExit("Run this script in Terminal to enter the key privately.")
		key = getpass.getpass("Gemini API key (hidden while typing/pasting): ").strip()
	if not key:
		raise SystemExit("No key entered.")
	print("\n1. List models (does not generate text)")
	names, token = [], None
	while True:
		path = "models?pageSize=1000"
		if token:
			path += "&pageToken=" + urllib.parse.quote(token, safe="")
		status, data = request(key, path)
		if status != 200:
			break
		names.extend(m["name"].removeprefix("models/") for m in data.get("models", [])
			if "generateContent" in m.get("supportedGenerationMethods", []))
		token = data.get("nextPageToken")
		if not token:
			break
	print("Models supporting generateContent:\n" + ("\n".join(names) or "[Could not list models]"))
	model = input(f"\nModel to test [{DEFAULT_MODEL}]: ").strip() or DEFAULT_MODEL
	model = model.removeprefix("models/")
	if not re.fullmatch(r"[A-Za-z0-9._-]+", model):
		raise SystemExit("Invalid model name.")
	print("\n2. Minimal generation request (small billable API request)")
	if generate(key, model, {"maxOutputTokens": 256}) != 200:
		print("Basic request failed; skipping optional settings tests.")
		return
	print("\nBasic generation accepted. This does not yet validate the app's request settings.")
	if input("Test the app's thinking setting too? [y/N]: ").strip().lower() != "y":
		return
	level = input("Thinking level [minimal]: ").strip() or "minimal"
	config = {"maxOutputTokens": 256, "thinkingConfig": {"thinkingLevel": level}}
	print("\n3. Thinking configuration")
	if generate(key, model, config) != 200:
		print("The added thinking setting caused this request to fail.")
		return
	if input("Test the app's responseFormat field too? [y/N]: ").strip().lower() != "y":
		return
	config["responseFormat"] = {"text": {"mimeType": "APPLICATION_JSON", "schema": {
		"type": "object", "properties": {"reply": {"type": "string"}}, "required": ["reply"]}}}
	print("\n4. App-style structured output (minimal schema, not the full route prompt)")
	generate(key, model, config)
	print("\nShare the HTTP error/message with me, not your key.")


if __name__ == "__main__":
	try:
		main()
	except (KeyboardInterrupt, EOFError):
		print("\nCancelled.")
