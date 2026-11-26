# authorizer-oneclick

A container image of [Authorizer](https://github.com/authorizerdev/authorizer) v2 for
one-click deploy buttons that can only set **an image, a port and environment variables**
(for example ZopDay).

Authorizer v2 reads **no environment variables**, only CLI flags. This image adds a small
POSIX entrypoint ([`entrypoint.sh`](entrypoint.sh)) that maps environment variables to flags,
fills in defaults so it starts with zero configuration, and then `exec`s the real binary
(it runs as PID 1, as the non-root `authorizer` user, uid 1000).

```
docker.io/lakhansamani/authorizer-oneclick:2.4.8    # Authorizer base version
docker.io/lakhansamani/authorizer-oneclick:latest
docker.io/lakhansamani/authorizer-oneclick:sha-<git sha>
```

Images are multi-arch (`linux/amd64`, `linux/arm64`) and are built from
`quay.io/authorizer/authorizer:<version>`. This repo tracks upstream Authorizer releases:
the base version is pinned by `ARG AUTHORIZER_VERSION` in the [`Dockerfile`](Dockerfile),
and bumping it publishes a new version tag and moves `latest`.

## Deploy

[![Deploy on ZopDay](https://zop.dev/deploytozopday-inkhard.svg)](https://zop.dev/zopday/app/deploy?image=docker.io/lakhansamani/authorizer-oneclick:latest&port=8080)

```markdown
[![Deploy on ZopDay](https://zop.dev/deploytozopday-inkhard.svg)](https://zop.dev/zopday/app/deploy?image=docker.io/lakhansamani/authorizer-oneclick:latest&port=8080)
```

Deploy links are public. **Never put a secret in the link.** Non-secret settings can be added
as `&env=NAME%3Dvalue`; set secrets in the platform's settings after deploy.

After the first deploy:

1. Copy the generated `ADMIN_SECRET` from the logs (see below) and log in at
   `<your URL>/dashboard`.
2. Set `AUTHORIZER_URL` to the deployment's public URL (for example
   `https://auth.example.com`) and redeploy.
3. For anything beyond a trial, follow [Production](#production).

Locally:

```sh
docker run -p 8080:8080 -v authorizer-data:/authorizer/data docker.io/lakhansamani/authorizer-oneclick:latest
```

## Environment variables

Every variable is optional. A flag is passed to the binary only when its variable is set and
non-empty; otherwise the binary's own default applies. The names are the same as the
[authorizer-railway](https://github.com/authorizerdev/authorizer-railway) and
[authorizer-render](https://github.com/authorizerdev/authorizer-render) templates, so their
docs carry over.

### Generated when unset

Stored on first boot in `/authorizer/data/secrets.env` (mode `0600`) and reused on later boots.
A value set in the environment always wins over the stored one.

| Variable | Flag | Notes |
| --- | --- | --- |
| `CLIENT_ID` | `--client-id` | |
| `CLIENT_SECRET` | `--client-secret` | |
| `JWT_SECRET` | `--jwt-secret` | Only for `HS*` `JWT_TYPE` (default `HS256`). For `RS*`/`ES*` set `JWT_PRIVATE_KEY`/`JWT_PUBLIC_KEY`. |
| `ENCRYPTION_KEY` | `--encryption-key` | Encrypts TOTP secrets and OTP digests at rest. Losing it locks out every TOTP user. |
| `ADMIN_SECRET` | `--admin-secret` | **Printed once** to the logs on the boot that generates it. See [Security](#security). |

### Defaulted by this image

| Variable | Flag | Default |
| --- | --- | --- |
| `DATABASE_TYPE` | `--database-type` | `sqlite` |
| `DATABASE_URL` | `--database-url` | `/authorizer/data/authorizer.db` (only when `DATABASE_TYPE=sqlite`) |
| `PORT` | `--http-port` | `8080` |
| `AUTHORIZER_URL` | `--url` | `http://localhost:$PORT`, with a warning. **Set it**: email links, the JWT `iss` claim and OIDC discovery are built from it. |
| `JWT_TYPE` | `--jwt-type` | `HS256` |
| `LOG_LEVEL` | `--log-level` | `info` |
| `DISABLE_ADMIN_HEADER_AUTH` | `--disable-admin-header-auth` | `true` (same hardened default as the Railway/Render templates) |

### Passed through when set

| Variables | Flags |
| --- | --- |
| `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_CERT`, `DATABASE_CA_CERT`, `DATABASE_CERT_KEY`, `REDIS_URL` | `--database-*`, `--redis-url` |
| `COUCHBASE_BUCKET`, `COUCHBASE_SCOPE`, `COUCHBASE_RAM_QUOTA`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `--couchbase-*`, `--aws-*` |
| `JWT_PRIVATE_KEY`, `JWT_PUBLIC_KEY`, `JWT_ROLE_CLAIM`, `JWT_SECONDARY_TYPE`, `JWT_SECONDARY_SECRET`, `JWT_SECONDARY_PRIVATE_KEY`, `JWT_SECONDARY_PUBLIC_KEY`, `CUSTOM_ACCESS_TOKEN_SCRIPT`, `REFRESH_TOKEN_EXPIRES_IN` | `--jwt-*`, `--custom-access-token-script`, `--refresh-token-expires-in` |
| `ROLES`, `DEFAULT_ROLES`, `PROTECTED_ROLES` | `--roles`, `--default-roles`, `--protected-roles` |
| `ALLOWED_ORIGINS`, `REDIRECT_URIS`, `TRUSTED_PROXIES`, `DEFAULT_AUTHORIZE_RESPONSE_TYPE`, `DEFAULT_AUTHORIZE_RESPONSE_MODE`, `OAUTH2_1_STRICT`, `RESET_PASSWORD_URL`, `BACKCHANNEL_LOGOUT_URI` | same names, kebab-case |
| `ORGANIZATION_NAME`, `ORGANIZATION_LOGO`, `ENV`, `HOST` | `--organization-name`, `--organization-logo`, `--env`, `--host` |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_SENDER_EMAIL` (or `SENDER_EMAIL`), `SMTP_SENDER_NAME` (or `SENDER_NAME`), `SMTP_LOCAL_NAME`, `SMTP_SKIP_TLS_VERIFICATION` | `--smtp-*` |
| `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY`, `TWILIO_API_SECRET`, `TWILIO_SENDER` | `--twilio-*` |
| `METRICS_PORT`, `METRICS_HOST`, `GRPC_PORT`, `ENABLE_GRPC_REFLECTION`, `GRPC_INSECURE`, `GRPC_TLS_CERT`, `GRPC_TLS_KEY` | `--metrics-*`, `--grpc-*`, `--enable-grpc-reflection` |
| `MCP_ENABLED`, `ENABLE_CLIENT_ID_METADATA_DOCUMENT`, `CLIENT_ID_METADATA_ALLOWED_DOMAINS`, `ENABLE_DYNAMIC_CLIENT_REGISTRATION` | same names, kebab-case |
| `FGA_STORE`, `FGA_STORE_URL`, `FGA_ALLOW_UNCONSTRAINED_AGENTS` | `--fga-*` |
| `RATE_LIMIT_RPS`, `RATE_LIMIT_BURST`, `RATE_LIMIT_FAIL_CLOSED` | `--rate-limit-*` |
| `ENABLE_LOGIN_PAGE`, `ENABLE_ORG_DISCOVERY`, `ENABLE_PLAYGROUND`, `ENABLE_GRAPHQL_INTROSPECTION`, `APP_COOKIE_SECURE`, `APP_COOKIE_SAME_SITE`, `ADMIN_COOKIE_SECURE`, `ENABLE_HSTS`, `DISABLE_CSP` | same names, kebab-case |
| `GRAPHQL_MAX_COMPLEXITY`, `GRAPHQL_MAX_DEPTH`, `GRAPHQL_MAX_ALIASES`, `GRAPHQL_MAX_BODY_BYTES` | `--graphql-max-*` |
| `ENABLE_SIGNUP`, `ENABLE_STRONG_PASSWORD`, `ENABLE_BASIC_AUTHENTICATION`, `ENABLE_MOBILE_BASIC_AUTHENTICATION`, `ENABLE_EMAIL_VERIFICATION`, `ENABLE_PHONE_VERIFICATION`, `ENABLE_MAGIC_LINK_LOGIN`, `ENFORCE_MFA`, `DISABLE_MFA`, `DISABLE_TOTP_LOGIN`, `DISABLE_WEBAUTHN_MFA`, `DISABLE_EMAIL_OTP`, `DISABLE_SMS_OTP` | same names, kebab-case |
| `{GOOGLE,GITHUB,FACEBOOK,MICROSOFT,APPLE,DISCORD,LINKEDIN,TWITCH,TWITTER,ROBLOX}_{CLIENT_ID,CLIENT_SECRET,SCOPES}`, `MICROSOFT_TENANT_ID`, `MICROSOFT_ALLOWED_TENANTS`, `OAUTH_ALLOW_UNVERIFIED_PROVIDER_EMAIL` | `--<provider>-client-id`, etc. |

Arguments passed to the container (`docker run ... IMAGE --flag=value`) are appended after the
env-derived flags, so they take precedence. The full flag reference is
`docker run --rm --entrypoint /authorizer/authorizer IMAGE --help`.

## Security

- **The generated `ADMIN_SECRET` is printed to the logs once.** That is the tradeoff that makes
  a zero-config deploy usable: there is no other way to hand you the dashboard credential, but
  it means the secret is in your platform's log history for as long as logs are retained, and
  anyone with log access can read it. Set your own `ADMIN_SECRET` in the platform's settings and
  redeploy as soon as you have logged in. On later boots the stored value is reused and is not
  printed again. No other secret is ever printed.
- **Never put secrets in a deploy link.** Deploy links are public.
- **`/authorizer/data` is ephemeral on platforms without volumes.** It holds the SQLite database
  *and* the generated secrets, so both are lost together when the container is replaced (every
  redeploy, on most one-click platforms). Treat a zero-config deploy as a trial.
- **Set `AUTHORIZER_URL`.** Without it the image falls back to `http://localhost:$PORT` so that
  the server can boot; links in emails, the JWT issuer and OIDC discovery then point at localhost.
- Authorizer v2 takes configuration only as flags, so secrets are visible in the process
  arguments inside the container (`ps`). This is inherent to v2, not specific to this image.
- If you mount a host directory (bind mount) at `/authorizer/data`, it must be writable by uid
  1000. Named volumes inherit the right owner from the image.

## Production

- Use a managed database: `DATABASE_TYPE=postgres` (or `mysql`, …) and `DATABASE_URL`.
- Set `CLIENT_ID`, `CLIENT_SECRET`, `JWT_SECRET` (or RSA/ECDSA keys), `ENCRYPTION_KEY` and
  `ADMIN_SECRET` explicitly, each a strong random value (`openssl rand -hex 32`). With an
  external database, secrets generated into an ephemeral `/authorizer/data` would change on
  every restart while the data survives — tokens would stop validating and TOTP users would be
  locked out. The entrypoint logs a warning in that case.
- Set `AUTHORIZER_URL`, `ALLOWED_ORIGINS`, `REDIRECT_URIS`, and `TRUSTED_PROXIES` for your
  platform's load balancer.

See the [Authorizer docs](https://docs.authorizer.dev) for every option.

## Development

```sh
docker build -t authorizer-oneclick:dev .                 # or --build-arg AUTHORIZER_VERSION=2.4.9
./scripts/smoke.sh authorizer-oneclick:dev               # zero env, restart, explicit secrets
```

CI ([`.github/workflows/publish.yml`](.github/workflows/publish.yml)) runs the same smoke test,
then publishes multi-arch images to Docker Hub (`docker.io/lakhansamani/authorizer-oneclick`,
using the `DOCKER_USERNAME` / `DOCKER_PASSWORD` repo secrets) on pushes to `main`, `v*` tags and manual runs
(`workflow_dispatch` takes an optional `authorizer_version`). Only the Dockerfile's pinned
version moves `latest`.

## License

Apache-2.0
