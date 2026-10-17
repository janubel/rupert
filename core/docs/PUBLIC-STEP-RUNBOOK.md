# Runbook: Rust Rupert on https://rrupert.stoverparc.org

Prepared 2026-10-17. **Nothing in this document has been applied.** Everything marked "owner" needs your `sudo`,
your Hover login or your Google account; everything marked "me" I can do over SSH once you say go.
Note the hostname has two r's (`rrupert`); the existing Rails site is `rupert.stoverparc.org`, one r.

## 0. What goes where

```
browser --https--> Caddy (192.168.3.251:443, shared)
                     rrupert.stoverparc.org
                       |- /hooks/* /healthz /api/v1/*  --> rupert-core 10.96.131.175:8798  (Rust app; authenticates itself)
                       `- everything else (login, signup, /oauth2/*) --> oauth2-proxy 10.96.131.175:4182 (Google sign-in)
                                                                            `--> Rust app 127.0.0.1:8798
```
Why two lanes: Shopify/Square webhooks and API clients with tokens cannot do a Google sign-in, so the paths they use go
straight to the app, which checks the provider signature or the bearer token on every request. Humans reach the login
and account endpoints only after Google. Signup is closed in the app regardless.

## 1. DNS (owner, Hover)

| Type | Host | Answer | TTL |
| --- | --- | --- | --- |
| **A** | `rrupert` | `71.162.207.117` | 900 |

That is the address `rupert.stoverparc.org`, `sonder.stoverparc.org` and the others already use. Use a real **A record**
in Hover's DNS tab, **not** Hover's "redirect/forwarding" feature: a redirect sends browsers to another URL and the
request never reaches Caddy, so no certificate can be issued. The domain has no CAA record, so Let's Encrypt can issue.
Check: `dig +short rrupert.stoverparc.org` returns `71.162.207.117`.

## 2. Google OAuth client (owner)

In the Google Cloud console, on the OAuth client you created: authorised redirect URI
`https://rrupert.stoverparc.org/oauth2/callback` (exactly, https, no trailing slash). The client secret never goes
through chat: you place it on the box in step 3.

## 3. Google sign-in proxy inside `rupert-core` (me, plus owner for the secret and the email list)

Same pattern as `energy.stoverparc.org` (oauth2-proxy v7.15.4). I copy the same binary container-to-container
(no download), create the files below, and you add the two values only you have.

`/etc/rrupert-oauth2-proxy.cfg` (no secrets in it except the client id, which is not secret):
```
provider = "google"
client_id = "<OWNER: Google client id>"
client_secret_file = "/var/lib/rrupert-auth/google-client-secret"
cookie_secret_file = "/var/lib/rrupert-auth/cookie-secret"
redirect_url = "https://rrupert.stoverparc.org/oauth2/callback"
http_address = "0.0.0.0:4182"
upstreams = ["http://127.0.0.1:8798/"]
authenticated_emails_file = "/etc/rrupert-oauth2-emails.txt"
scope = "openid email profile"
code_challenge_method = "S256"
reverse_proxy = true
trusted_proxy_ips = ["10.96.131.1/32"]
skip_provider_button = true
cookie_name = "__Host-rrupert"
cookie_secure = true
cookie_samesite = "lax"
cookie_expire = "24h"
pass_user_headers = true
whitelist_domains = ["rrupert.stoverparc.org"]
```
- `/etc/rrupert-oauth2-emails.txt`: one allowed Google email per line (**owner**: yours, and any buddy you want in).
  Unlike the energy site there is no `email_domains` line, so only listed people get in.
- `/var/lib/rrupert-auth/cookie-secret` (me: 32 random bytes), `/var/lib/rrupert-auth/google-client-secret`
  (**owner**, 0600, owned by `oauth2-proxy`):
  `incus exec rupert-core -- sh -c 'umask 077; cat > /var/lib/rrupert-auth/google-client-secret'` then paste, Enter, Ctrl-D.
- `/etc/systemd/system/rrupert-oauth2-proxy.service` (copy of the energy unit with this name, config and paths):
```
[Unit]
Description=Rupert core Google sign-in proxy
After=network-online.target rupert-core.service
Wants=network-online.target

[Service]
Type=simple
User=oauth2-proxy
Group=oauth2-proxy
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/rrupert-oauth2-proxy.cfg
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/rrupert-oauth2-proxy.cfg /etc/rrupert-oauth2-emails.txt /var/lib/rrupert-auth

[Install]
WantedBy=multi-user.target
```
The container already has the AppArmor signal rule, so `systemctl restart` works for both services.

## 4. The Caddy block (owner, needs `sudo`)

Append to `/etc/caddy/Caddyfile` (after the energy block). It was validated with `caddy validate` (Caddy 2.6.2) on SER8
against a scratch copy. The same text lives in `core/deploy/rrupert.caddy`; the proxy files are
`core/deploy/rrupert-oauth2-proxy.cfg` and `core/deploy/rrupert-oauth2-proxy.service`.

```
rrupert.stoverparc.org {
    import cockpit_incus_access
    bind 192.168.3.251

    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        -Server
    }

    # Compress everything except the event stream and webhook bodies.
    @compress not path /api/v1/events /hooks/*
    encode @compress zstd gzip

    # Machine endpoints authenticate themselves, so they must NOT sit behind a Google login:
    #   /hooks/*    provider HMAC signature + secret URL token
    #   /healthz    constant "ok"
    #   /api/v1/*   bearer API tokens or the app's own sessions (the app enforces auth on every route)
    @machine path /hooks/* /healthz /api/v1/*
    handle @machine {
        request_body {
            max_size 1MB
        }
        reverse_proxy 10.96.131.175:8798 {
            flush_interval -1
        }
    }

    # Everything else (login, signup, account endpoints, /oauth2/*, any future UI): Google sign-in first.
    handle {
        reverse_proxy 10.96.131.175:4182
    }
}
```
Apply (quiet window; Caddy runs with `admin off`, so a **restart** is needed, `systemctl reload` cannot work, and every
site on the host blips for a few seconds):
```
sudo cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-rrupert-$(date +%Y%m%d)
sudoedit /etc/caddy/Caddyfile            # paste the block at the end
sudo -u caddy /usr/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile   # must print "Valid configuration"
sudo systemctl restart caddy && systemctl is-active caddy
```
The certificate is requested on the first HTTPS request (TLS-ALPN, same as your other sites); allow about 10 seconds.

## 5. Verification matrix (me, after step 4)

| Request | Expected |
| --- | --- |
| `curl -sI https://rrupert.stoverparc.org/` | `302` to `accounts.google.com` (via `/oauth2/start`) |
| `curl -s https://rrupert.stoverparc.org/healthz` | `ok` |
| `curl -s -o /dev/null -w '%{http_code}' https://rrupert.stoverparc.org/api/v1/me` | `401` (JSON, `WWW-Authenticate: Bearer`) |
| `curl -s -XPOST -o /dev/null -w '%{http_code}' https://rrupert.stoverparc.org/hooks/shopify/rwh_notarealtoken0000000000000000000000000000000` | `404` |
| `curl -s -XPOST -o /dev/null -w '%{http_code}' https://rrupert.stoverparc.org/auth/login` (no Google cookie) | `302` to Google (login is behind the gate) |
| signed in with Google, then `POST /auth/signup` | `403 signups are closed` |
| response headers | `strict-transport-security`, `x-content-type-options`, no `server` |
| certificate | issued by Let's Encrypt for `rrupert.stoverparc.org` |
| every existing hostname (`swartzit`, `sonder`, `tasks`, `homeboard` (redirect), `rupert`, `herbalhealers`, `pos.rupertpos.com`, `daedalus`, `energy`, `stoverparc.org` (redirect)) | same status as before the restart |
| `scripts/parity.py` on SER8 | `RESULT: no differences` |

## 6. Rollback

1. `sudo cp -a /etc/caddy/Caddyfile.pre-rrupert-<date> /etc/caddy/Caddyfile && sudo systemctl restart caddy`.
2. Delete the Hover A record.
3. `incus exec rupert-core -- systemctl disable --now rrupert-oauth2-proxy` (optional).
4. App state: `incus snapshot restore rupert-core phase4-baseline-5299b7e` (or a newer snapshot taken in step 0 below).
Rails and every other site are untouched by any of this.

## 7. Pre-flight checklist

- [ ] Hover **A record** `rrupert` -> `71.162.207.117` (not a redirect); `dig` confirms.
- [ ] Google OAuth redirect URI added; client id and secret ready; allowed-email list decided.
- [ ] **Hardened build deployed to `rupert-core`** (me, on your go): signup closed by default, `POST /api/v1/me/password`,
      health endpoint, graceful stop. Needs a fresh x86_64 build (about 2 minutes), tests on the host, a snapshot first,
      then `systemctl restart rupert-core`. The running build (`5299b7e`) still has **open signup**: do not expose it.
- [ ] `RUPERT_PUBLIC_URL=https://rrupert.stoverparc.org` in `/etc/rupert-core/env`; `RUPERT_DEV` and `RUPERT_SIGNUP` unset.
- [ ] Owner password changed (`POST /api/v1/me/password`) and the owner email corrected from the placeholder
      `owner@rupert-core.local`.
- [ ] Snapshot of `rupert-core` taken immediately before step 4.
- [ ] Quiet window chosen for the Caddy restart; you are watching a second site (for example `energy`) while it happens.
- [ ] You have the rollback commands in step 6 at hand.

## 8. Known limits

- Behind the Google proxy the app sees one client address for rate-limit purposes (the proxy's), so the per-IP limits
  on gated routes are weaker; per-account and per-token limits still apply, and Google is the first factor.
- `/api/v1/*` is intentionally outside the Google gate. It is protected by 256-bit bearer tokens or sessions, rate
  limits and the request budget, not by Google. If you prefer, tell me and I will put only `/hooks/*` and `/healthz`
  outside the gate and give API clients a separate hostname.
- The app has no MFA of its own; Google sign-in plays that role for human access. Webhooks are not registered yet
  (that is a write to Shopify/Square and needs your approval). Scheduled syncs and the backup timer are still off.
