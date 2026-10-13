# Current mobile authentication configuration

The native app uses `server/app.py`, `server/cloud.py` and `server/email_flow.py`.
The server does not serve the archived HTML prototype.

Copy `.env.example` to a private `.env` and supply your own project settings.
Keep server-only Supabase credentials out of the iOS target and Git.
`W8G_AUTH_BASE_URL` must be reachable by the device opening confirmation emails.
For this local setup its default is `http://MacBook-Pro.local:8787`.

In Supabase Authentication URL Configuration, use `<W8G_AUTH_BASE_URL>/auth/result`
as the fallback Site URL and allow `<W8G_AUTH_BASE_URL>/auth/callback/*` as the
redirect. Keep email confirmation enabled. For deployment, use your own public
HTTPS origin and matching callback allowlist. Old emails retain their original
URLs; request a fresh email after changing configuration.

Email links prove ownership on the server. The requesting phone holds its private
recovery ticket and polls for confirmation, then accepts the new password inside
the app. The browser displays a receipt, not a password form or the prototype.
The phone and a local server must be reachable on the same network for local
links; a public HTTPS deployment removes that LAN requirement.

The archived step-by-step Swift snippets are historical and must not be pasted
over the current implementation. No cloud configuration was changed by the
multi-stop feature or documentation cleanup.
