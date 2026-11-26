#!/bin/sh
# Smoke test for the one-click image. Usage: scripts/smoke.sh IMAGE [HOST_PORT]
#
# 1. Zero env vars: boots, /healthz is 200, the generated ADMIN_SECRET is
#    printed once and logs in, a user can sign up.
# 2. Restart on the same volume: same persisted secrets, ADMIN_SECRET is not
#    printed again, the user still exists and can log in.
# 3. Explicit env secrets on a fresh volume: they are used, nothing generated
#    or printed.
set -eu

IMAGE=${1:?usage: smoke.sh IMAGE [HOST_PORT]}
HPORT=${2:-18080}
P=oneclick_smoke_$$
BASE="http://localhost:$HPORT"
EMAIL="smoke@example.com"
PASSWORD="Sm0ke-Test-Passw0rd!"

fail() { echo "FAIL: $*" >&2; docker logs "$P" 2>&1 | tail -n 40 >&2 || true; exit 1; }
cleanup() {
	docker rm -f "$P" >/dev/null 2>&1 || true
	docker volume rm -f "${P}_v1" "${P}_v2" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
	i=0
	until [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")" = 200 ]; do
		i=$((i + 1))
		[ "$i" -lt 60 ] || fail "/healthz did not return 200 within 60s"
		docker inspect -f '{{.State.Running}}' "$P" 2>/dev/null | grep -q true || fail "container exited"
		sleep 1
	done
	echo "ok: /healthz 200"
}

gql() { # $1 = JSON body, extra curl args after
	body=$1
	shift
	curl -sS "$BASE/graphql" -H 'Content-Type: application/json' -H "Origin: $BASE" "$@" -d "$body"
}

secrets_sum() { docker exec "$P" sha256sum /authorizer/data/secrets.env | cut -d' ' -f1; }

run() { # $1 = volume, remaining = extra docker args
	vol=$1
	shift
	docker rm -f "$P" >/dev/null 2>&1 || true
	docker run -d --name "$P" -p "$HPORT:8080" -v "$vol:/authorizer/data" "$@" "$IMAGE" >/dev/null
}

echo "== 1. zero-config first boot"
run "${P}_v1"
wait_healthy
ADMIN=$(docker logs "$P" 2>&1 | sed -n 's/.*ADMIN_SECRET=\([0-9a-f]\{64\}\)$/\1/p' | head -n 1)
[ -n "$ADMIN" ] || fail "generated ADMIN_SECRET not printed"
echo "ok: generated ADMIN_SECRET printed"
[ "$(docker exec "$P" stat -c '%a %u' /authorizer/data/secrets.env)" = "600 1000" ] || fail "secrets.env is not 0600 owned by uid 1000"
echo "ok: secrets.env is 0600, uid 1000"
for k in CLIENT_SECRET JWT_SECRET ENCRYPTION_KEY; do
	v=$(docker exec "$P" sed -n "s/^$k=//p" /authorizer/data/secrets.env)
	[ -n "$v" ] || fail "$k not persisted"
	docker logs "$P" 2>&1 | grep -q "$v" && fail "$k value leaked into logs"
done
echo "ok: other secrets persisted and not logged"
SUM1=$(secrets_sum)

admin_login() {
	hdrs=$(mktemp)
	out=$(gql "{\"query\":\"mutation{_admin_login(params:{admin_secret:\\\"$1\\\"}){message}}\"}" -D "$hdrs")
	echo "$out" | grep -q '"errors"' && { rm -f "$hdrs"; fail "admin login failed: $out"; }
	cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' "$hdrs" | head -n 1)
	rm -f "$hdrs"
	[ -n "$cookie" ] || fail "admin login set no cookie"
	echo "$cookie"
}
COOKIE=$(admin_login "$ADMIN")
echo "ok: admin login with printed secret"

out=$(gql "{\"query\":\"mutation{signup(params:{email:\\\"$EMAIL\\\",password:\\\"$PASSWORD\\\",confirm_password:\\\"$PASSWORD\\\"}){message}}\"}")
echo "$out" | grep -q '"errors"' && fail "signup failed: $out"
echo "ok: signup"

echo "== 2. restart on the same volume"
docker stop -t 20 "$P" >/dev/null
run "${P}_v1"
wait_healthy
[ "$(secrets_sum)" = "$SUM1" ] || fail "secrets.env changed across restart"
docker logs "$P" 2>&1 | grep -q "$ADMIN" && fail "ADMIN_SECRET printed again on restart"
docker logs "$P" 2>&1 | grep -q 'using the value generated on first boot' || fail "restart did not reuse saved ADMIN_SECRET"
echo "ok: same secrets, ADMIN_SECRET not printed again"
COOKIE=$(admin_login "$ADMIN")
out=$(gql '{"query":"query{_users{users{email}}}"}' -H "Cookie: $COOKIE")
echo "$out" | grep -q "$EMAIL" || fail "user did not persist: $out"
echo "ok: user persisted (admin _users)"
out=$(gql "{\"query\":\"mutation{login(params:{email:\\\"$EMAIL\\\",password:\\\"$PASSWORD\\\"}){message}}\"}")
echo "$out" | grep -q '"errors"' && fail "user login failed after restart: $out"
echo "ok: user login after restart"

echo "== 3. explicit secrets"
EXPLICIT_ADMIN=explicit-admin-$$-0123456789abcdef
run "${P}_v2" \
	-e CLIENT_ID=explicit-client-id -e CLIENT_SECRET=explicit-client-secret-0123456789 \
	-e JWT_SECRET=explicit-jwt-secret-0123456789abcdef -e ENCRYPTION_KEY=explicit-enc-key-0123456789abcdef \
	-e ADMIN_SECRET="$EXPLICIT_ADMIN" -e AUTHORIZER_URL="$BASE"
wait_healthy
docker exec "$P" test -e /authorizer/data/secrets.env && fail "secrets.env written although all secrets were set"
for v in "$EXPLICIT_ADMIN" explicit-client-secret-0123456789 explicit-jwt-secret-0123456789abcdef explicit-enc-key-0123456789abcdef; do
	docker logs "$P" 2>&1 | grep -q -- "$v" && fail "explicit secret leaked into logs"
done
docker logs "$P" 2>&1 | grep -q 'Generated and saved' && fail "something was generated"
admin_login "$EXPLICIT_ADMIN" >/dev/null
echo "ok: explicit ADMIN_SECRET works, nothing generated or printed"
out=$(curl -sS "$BASE/.well-known/openid-configuration")
echo "$out" | grep -q "\"issuer\":\"$BASE\"" || fail "AUTHORIZER_URL not applied: $out"
echo "ok: AUTHORIZER_URL applied"

echo "PASS"
