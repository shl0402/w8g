> The native iOS app uses this server contract. Email callback configuration is in [AUTH_CONFIGURATION.md](AUTH_CONFIGURATION.md). Historical browser setup guides are archived outside this repository.

# w8g mobile service contract

The Swift app uses the w8g backend, Supabase Auth users and database tables. The earlier HTML prototype is a design reference only; this server no longer serves it. Native authentication uses AuthService.swift and AppSession.swift.

## Transport and session

JSON requests and responses; POST requests use Content-Type: application/json. Login sets an opaque `w8g` HttpOnly, SameSite=Strict cookie. The native app uses a Swift URLSession; a URLSession with cookie handling enabled can use the same endpoints; retain the cookie in its private cookie storage and discard it on logout. Supabase access/refresh tokens and the service key remain on the backend. Never bundle server secrets in the app.

Use a deployed HTTPS backend for a physical phone. Localhost on an iPhone means the phone itself, not this Mac. Production needs Secure cookies and a configured HTTPS reverse proxy; the server defaults to localhost; W8G_HOST=0.0.0.0 enables LAN access for development.

## Account endpoints

| Method / path | Request | Response |
| --- | --- | --- |
| POST /api/signup | username, email, password | confirmation message, requestToken, expiresAt; no login session when Supabase confirmation is enabled |
| POST /api/login | login (username or email), password | user: {id, username, email}; session cookie |
| GET /api/session | cookie | user or null |
| POST /api/logout | {} and cookie | ok; expires local session and requests Supabase sign-out |
| POST /api/profile | username and/or password, currentPassword | updated user |
| POST /api/recover | email | generic message, private requestToken, expiresAt (Unix seconds) |
| POST /api/recovery/status | requestToken | state: pending, confirmed, expired, or used; invalid/unknown ticket is rejected |
| POST /api/recovery/finish | requestToken, password | requires verified recovery; message after password update |
| POST /api/recovery-session | obsolete | 410; provider tokens must not be passed from a browser |

Email links use the server callback `/auth/callback/<request-id>`. Supabase verifies the email and the server exchanges the PKCE code, checks its identity and records approval. The requesting app polls status while active and reveals new-password fields on the same screen. No eight-digit code is used. Browsers receive only a confirmation receipt, never the prototype, a password form or a login session. See [PASSWORD_RESET_AUTO_CONFIRM.md](AUTH_CONFIGURATION.md) for current Swift edits and callback settings.

The backend verifies the authenticated identity before protected requests and refreshes expired tokens. Temporary cloud outages return 503 and preserve the stored session for retry. Invalid refresh credentials return 401. Clients must not confuse a temporary network failure with sign-out.

## Saved routes and history

GET /api/records returns records `{id, kind, payload, updated}`. `kind` is `saved` or `history`; `updated` is Unix seconds. The route payload is shared JSON, including route geometry and journey legs for offline storage. POST /api/records accepts `{id, kind, payload}` for atomic upsert or `{id, kind, delete:true}` for deletion. Record IDs contain letters, numbers, underscores or hyphens, maximum 100 characters.

The backend derives ownership from the session. A supplied user_id cannot select another account. Database RLS additionally restricts rows to auth.uid(). Route reads and writes use the user's token, not the service key. The optional service key is only needed for private username-to-email lookup; email login works without it.

Persist explicitly saved routes and downloaded maps on the device for offline use. Offline mode does not call authenticated online endpoints. Sign in on either client to access the same cloud records; completed route-search history is retried from the server outbox during synchronization.

## AI and routing

POST /api/ai accepts text and optional messages [{role, text}]. Shared Gemini credentials stay on the backend. For an AI route, confirm/edit locations before POST /api/drafts, then POST /api/jobs with ai:true, draftId, revision and confirmed:true. Ordinary Explore routing uses POST /api/jobs directly. Poll GET /api/jobs/:id for completion.

## Verification status

`tests/test_cloud_services.py` and `tests/test_supabase_contract.py` exercise the shared server with mocked external services, including login, verification-required signup, route ownership, CRUD, refresh, outage retry and logout. On 26 September 2026, live checks also passed against the w8g project: username/email login, saved-route sync between independent HTTP sessions, deletion and account isolation. Database RLS checks passed in a rolled-back test transaction. A physical Swift client and email delivery have not yet been tested.


### Multi-stop trip boundaries

Multi-stop journey responses optionally include `trips` in visit order. Each entry has
`legStartIndex` (inclusive), `legEndIndex` (exclusive), `duration` (seconds), `start`,
`end`, `departure`, `transfers`, and `walkDistance` (metres). Entry i travels from
`stops[i]` to `stops[i+1]`; its geometry and transit instructions remain in the
parent `legs` array. Ordered and optimised searches both supply these boundaries.
Old saved responses and one-to-one responses may omit `trips` or return null.
Keep this optional field when saving, synchronising, or sharing a journey.


### Stay times

`POST /api/jobs` accepts optional `defaultStayMinutes` (integer 0–720, default 0)
and `stopStayMinutes` (an array matching `stops`, whose values are integers 0–720
or null). Missing/null entries inherit the default for intermediate stops; the
original first and last stop default to 0. Explicit 0 overrides the default.
These are destination visit/rest times, not transit-station waiting times.

Ordered routing adds each stay before requesting the next leg. Optimised routing
passes resolved values as each solver job’s `serviceMinutes`, so time follows the
location even if it becomes first or last. Responses contain resolved
`stopStayMinutes` in the returned visit order. Final stays extend `end`; initial
stays are included in `start`/total duration. Individual `trips` remain travel-only.
Saving/sharing must retain the resolved values. Alternatives for one trip must
leave after the preceding stay and allow the following stay before its departure.
