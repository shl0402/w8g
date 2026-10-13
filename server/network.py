import ssl, os, urllib.request

CONTEXT = ssl.create_default_context(
	cafile="/etc/ssl/cert.pem" if os.path.exists("/etc/ssl/cert.pem") else None
)


def urlopen(request, timeout=20):
	return urllib.request.urlopen(request, timeout=timeout, context=CONTEXT)
