#!/usr/bin/env bash
set -euo pipefail

# Run on the staging host as root after the encrypted filesystem is mounted.
# Source checkout stays outside the secure mount; only operational data lives
# below /srv/torchat/staging.
REPO_ROOT=${1:?usage: bootstrap-staging.sh /path/to/torchat}
SECURE_ROOT=${TORCHAT_SECURE_ROOT:-/srv/torchat/staging}
SERVICE_USER=${TORCHAT_SERVICE_USER:-torchat}

test -d "$REPO_ROOT/.git" || { echo "Not a TorChat checkout: $REPO_ROOT" >&2; exit 1; }
mountpoint -q "$(dirname "$(dirname "$SECURE_ROOT")")" || {
  echo "The encrypted TorChat filesystem is not mounted." >&2; exit 1;
}
id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$SECURE_ROOT/postgres" "$SECURE_ROOT/onion" "$SECURE_ROOT/secrets"

if [[ ! -s "$SECURE_ROOT/secrets/postgres_password" ]]; then
  umask 077
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 >"$SECURE_ROOT/secrets/postgres_password"
fi
if [[ ! -s "$SECURE_ROOT/secrets/database_url" ]]; then
  password=$(<"$SECURE_ROOT/secrets/postgres_password")
  umask 077
  printf 'postgres://torchat:%s@postgres:5432/torchat\n' "$password" >"$SECURE_ROOT/secrets/database_url"
fi
if [[ ! -s "$SECURE_ROOT/secrets/pairing_secret" ]]; then
  umask 077
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 >"$SECURE_ROOT/secrets/pairing_secret"
fi
chown "$SERVICE_USER:$SERVICE_USER" \
  "$SECURE_ROOT/secrets/postgres_password" \
  "$SECURE_ROOT/secrets/database_url" \
  "$SECURE_ROOT/secrets/pairing_secret"
chmod 0600 \
  "$SECURE_ROOT/secrets/postgres_password" \
  "$SECURE_ROOT/secrets/database_url" \
  "$SECURE_ROOT/secrets/pairing_secret"

install -m 0644 "$REPO_ROOT/infra/host/torchat-staging.service" /etc/systemd/system/torchat-staging.service
systemctl daemon-reload
echo "Provisioned $SECURE_ROOT. Configure TORCHAT_ONION_URL and TORCHAT_SECURE_ROOT in /etc/torchat/staging.env, then enable with: systemctl enable --now torchat-staging"
