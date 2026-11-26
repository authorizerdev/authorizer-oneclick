#!/bin/sh
# Entrypoint for the Authorizer one-click image.
#
# Authorizer v2 reads no environment variables, only CLI flags. Deploy buttons
# (ZopDay, etc.) can only set an image, a port and environment variables, so
# this script maps env vars onto flags, then execs the real binary so it runs
# as PID 1 and receives SIGTERM directly.
#
# Rules:
#   * A flag is passed only when its env var is set and non-empty. Unset vars
#     fall through to the binary's own defaults.
#   * CLIENT_ID, CLIENT_SECRET, JWT_SECRET (HS* only), ENCRYPTION_KEY and
#     ADMIN_SECRET are generated on first boot when not provided, and persisted
#     in $DATA_DIR/secrets.env (mode 0600) so restarts keep tokens and TOTP valid.
#   * A generated ADMIN_SECRET is printed to the log exactly once, on the boot
#     that generates it. No other secret is ever printed.
#   * Extra arguments given to the container are appended after the env-derived
#     flags, so they win for scalar flags.
set -eu

DATA_DIR=/authorizer/data
SECRETS_FILE="$DATA_DIR/secrets.env"

log() { printf '[authorizer-oneclick] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Defaults for a zero-config start (SQLite on the local data dir).
# ---------------------------------------------------------------------------
: "${DATABASE_TYPE:=sqlite}"
if [ "$DATABASE_TYPE" = "sqlite" ] && [ -z "${DATABASE_URL:-}" ]; then
	DATABASE_URL="$DATA_DIR/authorizer.db"
fi
: "${PORT:=8080}"
: "${LOG_LEVEL:=info}"
# Same hardened default as the Railway/Render templates: admin auth only via
# the admin cookie, not the X-Authorizer-Admin-Secret header.
: "${DISABLE_ADMIN_HEADER_AUTH:=true}"
# Accept the names used in the Railway README as well as its Dockerfile.
: "${SENDER_EMAIL:=${SMTP_SENDER_EMAIL:-}}"
: "${SENDER_NAME:=${SMTP_SENDER_NAME:-}}"

if [ -z "${AUTHORIZER_URL:-}" ]; then
	AUTHORIZER_URL="http://localhost:$PORT"
	log "WARNING: AUTHORIZER_URL is not set; using $AUTHORIZER_URL so the server can boot."
	log "WARNING: email links, the JWT iss claim and OIDC discovery will point at localhost."
	log "WARNING: set AUTHORIZER_URL to this deployment's public URL (e.g. https://auth.example.com) and redeploy."
fi

# ---------------------------------------------------------------------------
# Generated secrets.
# ---------------------------------------------------------------------------
gen_secret() {
	# 32 random bytes, hex encoded (64 chars).
	head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n'
}

# Read KEY from the secrets file without sourcing it.
read_saved() {
	[ -f "$SECRETS_FILE" ] || return 0
	sed -n "s/^$1=//p" "$SECRETS_FILE" | tail -n 1
}

GENERATED=""
ensure_secret() {
	name=$1
	eval "current=\${$name:-}"
	if [ -n "$current" ]; then
		return 0
	fi
	saved=$(read_saved "$name")
	if [ -n "$saved" ]; then
		eval "$name=\$saved"
		return 0
	fi
	if ! { [ -d "$DATA_DIR" ] && [ -w "$DATA_DIR" ]; }; then
		log "FATAL: $name is not set and $DATA_DIR is not writable, so a generated value could not be persisted."
		log "FATAL: either set $name explicitly or make $DATA_DIR writable by uid $(id -u)."
		exit 1
	fi
	value=$(gen_secret)
	(umask 077 && printf '%s=%s\n' "$name" "$value" >>"$SECRETS_FILE")
	chmod 600 "$SECRETS_FILE"
	eval "$name=\$value"
	GENERATED="$GENERATED $name"
}

ensure_secret CLIENT_ID
ensure_secret CLIENT_SECRET
ensure_secret ENCRYPTION_KEY
case "${JWT_TYPE:-}" in
"" | HS*)
	: "${JWT_TYPE:=HS256}"
	ensure_secret JWT_SECRET
	;;
esac

admin_generated=false
if [ -z "${ADMIN_SECRET:-}" ]; then
	if [ -n "$(read_saved ADMIN_SECRET)" ]; then
		log "ADMIN_SECRET not set; using the value generated on first boot (stored in $SECRETS_FILE)."
	else
		admin_generated=true
	fi
	ensure_secret ADMIN_SECRET
fi

if [ -n "$GENERATED" ]; then
	log "Generated and saved to $SECRETS_FILE:$GENERATED"
	if [ "$DATABASE_TYPE" != "sqlite" ]; then
		log "WARNING: DATABASE_TYPE=$DATABASE_TYPE is external, but generated secrets live in $DATA_DIR."
		log "WARNING: if $DATA_DIR is not a persistent volume these change on restart (tokens and TOTP break). Set them explicitly."
	fi
fi

if [ "$admin_generated" = true ]; then
	log "======================================================================"
	log "ADMIN_SECRET was not set, so one was generated. It is shown ONLY ONCE:"
	log ""
	log "    ADMIN_SECRET=$ADMIN_SECRET"
	log ""
	log "Use it to log in to the dashboard at $AUTHORIZER_URL/dashboard."
	log "It is now in your platform's log history: set ADMIN_SECRET yourself and"
	log "redeploy (or change it from the dashboard) as soon as possible."
	log "======================================================================"
fi

# ---------------------------------------------------------------------------
# env var -> flag mapping (same names as the authorizer-railway template).
# ---------------------------------------------------------------------------
MAP="
DATABASE_TYPE:database-type
DATABASE_URL:database-url
DATABASE_NAME:database-name
DATABASE_USERNAME:database-username
DATABASE_PASSWORD:database-password
DATABASE_HOST:database-host
DATABASE_PORT:database-port
DATABASE_CERT:database-cert
DATABASE_CA_CERT:database-ca-cert
DATABASE_CERT_KEY:database-cert-key
CLIENT_ID:client-id
CLIENT_SECRET:client-secret
ADMIN_SECRET:admin-secret
REDIS_URL:redis-url
JWT_TYPE:jwt-type
JWT_SECRET:jwt-secret
ENCRYPTION_KEY:encryption-key
JWT_PRIVATE_KEY:jwt-private-key
JWT_PUBLIC_KEY:jwt-public-key
JWT_ROLE_CLAIM:jwt-role-claim
JWT_SECONDARY_TYPE:jwt-secondary-type
JWT_SECONDARY_SECRET:jwt-secondary-secret
JWT_SECONDARY_PRIVATE_KEY:jwt-secondary-private-key
JWT_SECONDARY_PUBLIC_KEY:jwt-secondary-public-key
CUSTOM_ACCESS_TOKEN_SCRIPT:custom-access-token-script
ROLES:roles
DEFAULT_ROLES:default-roles
PROTECTED_ROLES:protected-roles
ALLOWED_ORIGINS:allowed-origins
REDIRECT_URIS:redirect-uris
DEFAULT_AUTHORIZE_RESPONSE_TYPE:default-authorize-response-type
DEFAULT_AUTHORIZE_RESPONSE_MODE:default-authorize-response-mode
OAUTH2_1_STRICT:oauth2-1-strict
ORGANIZATION_NAME:organization-name
ORGANIZATION_LOGO:organization-logo
SMTP_HOST:smtp-host
SMTP_PORT:smtp-port
SMTP_USERNAME:smtp-username
SMTP_PASSWORD:smtp-password
SENDER_EMAIL:smtp-sender-email
SENDER_NAME:smtp-sender-name
SMTP_LOCAL_NAME:smtp-local-name
SMTP_SKIP_TLS_VERIFICATION:smtp-skip-tls-verification
RESET_PASSWORD_URL:reset-password-url
BACKCHANNEL_LOGOUT_URI:backchannel-logout-uri
AUTHORIZER_URL:url
ENV:env
HOST:host
PORT:http-port
METRICS_PORT:metrics-port
METRICS_HOST:metrics-host
GRPC_PORT:grpc-port
ENABLE_GRPC_REFLECTION:enable-grpc-reflection
GRPC_INSECURE:grpc-insecure
GRPC_TLS_CERT:grpc-tls-cert
GRPC_TLS_KEY:grpc-tls-key
MCP_ENABLED:mcp-enabled
ENABLE_CLIENT_ID_METADATA_DOCUMENT:enable-client-id-metadata-document
CLIENT_ID_METADATA_ALLOWED_DOMAINS:client-id-metadata-allowed-domains
ENABLE_DYNAMIC_CLIENT_REGISTRATION:enable-dynamic-client-registration
RATE_LIMIT_RPS:rate-limit-rps
RATE_LIMIT_BURST:rate-limit-burst
RATE_LIMIT_FAIL_CLOSED:rate-limit-fail-closed
ENABLE_LOGIN_PAGE:enable-login-page
ENABLE_ORG_DISCOVERY:enable-org-discovery
ENABLE_PLAYGROUND:enable-playground
DISABLE_ADMIN_HEADER_AUTH:disable-admin-header-auth
ENABLE_GRAPHQL_INTROSPECTION:enable-graphql-introspection
APP_COOKIE_SECURE:app-cookie-secure
APP_COOKIE_SAME_SITE:app-cookie-same-site
ADMIN_COOKIE_SECURE:admin-cookie-secure
TRUSTED_PROXIES:trusted-proxies
REFRESH_TOKEN_EXPIRES_IN:refresh-token-expires-in
ENABLE_HSTS:enable-hsts
DISABLE_CSP:disable-csp
GRAPHQL_MAX_COMPLEXITY:graphql-max-complexity
GRAPHQL_MAX_DEPTH:graphql-max-depth
GRAPHQL_MAX_ALIASES:graphql-max-aliases
GRAPHQL_MAX_BODY_BYTES:graphql-max-body-bytes
FGA_STORE:fga-store
FGA_STORE_URL:fga-store-url
FGA_ALLOW_UNCONSTRAINED_AGENTS:fga-allow-unconstrained-agents
COUCHBASE_BUCKET:couchbase-bucket
COUCHBASE_SCOPE:couchbase-scope
COUCHBASE_RAM_QUOTA:couchbase-ram-quota
AWS_REGION:aws-region
AWS_ACCESS_KEY_ID:aws-access-key-id
AWS_SECRET_ACCESS_KEY:aws-secret-access-key
ENABLE_STRONG_PASSWORD:enable-strong-password
ENABLE_BASIC_AUTHENTICATION:enable-basic-authentication
ENABLE_EMAIL_VERIFICATION:enable-email-verification
ENABLE_MOBILE_BASIC_AUTHENTICATION:enable-mobile-basic-authentication
ENABLE_PHONE_VERIFICATION:enable-phone-verification
ENABLE_MAGIC_LINK_LOGIN:enable-magic-link-login
ENFORCE_MFA:enforce-mfa
DISABLE_TOTP_LOGIN:disable-totp-login
DISABLE_WEBAUTHN_MFA:disable-webauthn-mfa
DISABLE_EMAIL_OTP:disable-email-otp
DISABLE_SMS_OTP:disable-sms-otp
DISABLE_MFA:disable-mfa
ENABLE_SIGNUP:enable-signup
TWILIO_ACCOUNT_SID:twilio-account-sid
TWILIO_API_KEY:twilio-api-key
TWILIO_API_SECRET:twilio-api-secret
TWILIO_SENDER:twilio-sender
GOOGLE_CLIENT_ID:google-client-id
GOOGLE_CLIENT_SECRET:google-client-secret
GOOGLE_SCOPES:google-scopes
GITHUB_CLIENT_ID:github-client-id
GITHUB_CLIENT_SECRET:github-client-secret
GITHUB_SCOPES:github-scopes
FACEBOOK_CLIENT_ID:facebook-client-id
FACEBOOK_CLIENT_SECRET:facebook-client-secret
FACEBOOK_SCOPES:facebook-scopes
MICROSOFT_CLIENT_ID:microsoft-client-id
MICROSOFT_CLIENT_SECRET:microsoft-client-secret
MICROSOFT_TENANT_ID:microsoft-tenant-id
MICROSOFT_ALLOWED_TENANTS:microsoft-allowed-tenants
MICROSOFT_SCOPES:microsoft-scopes
OAUTH_ALLOW_UNVERIFIED_PROVIDER_EMAIL:oauth-allow-unverified-provider-email
APPLE_CLIENT_ID:apple-client-id
APPLE_CLIENT_SECRET:apple-client-secret
APPLE_SCOPES:apple-scopes
DISCORD_CLIENT_ID:discord-client-id
DISCORD_CLIENT_SECRET:discord-client-secret
DISCORD_SCOPES:discord-scopes
LINKEDIN_CLIENT_ID:linkedin-client-id
LINKEDIN_CLIENT_SECRET:linkedin-client-secret
LINKEDIN_SCOPES:linkedin-scopes
TWITCH_CLIENT_ID:twitch-client-id
TWITCH_CLIENT_SECRET:twitch-client-secret
TWITCH_SCOPES:twitch-scopes
TWITTER_CLIENT_ID:twitter-client-id
TWITTER_CLIENT_SECRET:twitter-client-secret
TWITTER_SCOPES:twitter-scopes
ROBLOX_CLIENT_ID:roblox-client-id
ROBLOX_CLIENT_SECRET:roblox-client-secret
ROBLOX_SCOPES:roblox-scopes
LOG_LEVEL:log-level
"

# Append env-derived flags after any container arguments, then rotate the
# original arguments to the end so explicit CLI arguments take precedence.
nargs=$#
for pair in $MAP; do
	var=${pair%%:*}
	flag=${pair#*:}
	eval "val=\${$var:-}"
	if [ -n "$val" ]; then
		set -- "$@" "--$flag=$val"
	fi
done
i=0
while [ "$i" -lt "$nargs" ]; do
	set -- "$@" "$1"
	shift
	i=$((i + 1))
done

exec /authorizer/authorizer "$@"
