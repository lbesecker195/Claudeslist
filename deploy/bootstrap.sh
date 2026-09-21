#!/usr/bin/env bash
# One-time server setup for ClaudesList on Ubuntu 24.04 with nginx, certbot,
# PostgreSQL and Elixir already installed. Run as root from a checkout:
#
#     sudo deploy/bootstrap.sh
#
# Safe to re-run: every step checks before it acts, and it never overwrites
# an existing env file, database password, or TLS certificate.
#
# Env overrides: CLAUDESLIST_HOST, CLAUDESLIST_PORT, CERTBOT_EMAIL,
# CLAUDESLIST_SKIP_TLS=1 (skip certbot, e.g. before DNS points here).
set -euo pipefail

APP=claudeslist
BUILD_USER=claudeslist-build
HOST="${CLAUDESLIST_HOST:-claudeslist.loganbesecker.com}"
PORT="${CLAUDESLIST_PORT:-4070}"
EMAIL="${CERTBOT_EMAIL:-}"
ROOT=/opt/claudeslist
ENV_DIR=/etc/claudeslist
ENV_FILE="$ENV_DIR/claudeslist.env"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

if ss -ltn "sport = :$PORT" | grep -q LISTEN && ! systemctl is-active --quiet "$APP"; then
  echo "port $PORT is already in use by something else; set CLAUDESLIST_PORT" >&2
  exit 1
fi

log "system users and directories"
# Runtime user: runs the release. Build user: compiles deps and assets, so
# third-party build code never runs as root or sees production secrets.
id "$APP" >/dev/null 2>&1 || useradd --system --home-dir "$ROOT" --shell /usr/sbin/nologin "$APP"
id "$BUILD_USER" >/dev/null 2>&1 ||
  useradd --system --home-dir "$ROOT/build-home" --shell /usr/sbin/nologin "$BUILD_USER"
install -d -m 755 -o root -g root "$ROOT"
install -d -m 755 -o "$BUILD_USER" -g "$BUILD_USER" "$ROOT/releases" "$ROOT/src"
install -d -m 700 -o "$BUILD_USER" -g "$BUILD_USER" "$ROOT/build-home"
install -d -m 750 -o root -g "$APP" "$ENV_DIR"
install -m 755 "$HERE/deploy.sh" "$ROOT/deploy.sh"

log "postgres role and database"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$APP'" | grep -q 1; then
  DB_PASS=$(openssl rand -hex 24)
  # Via stdin so the password never shows up in the process list.
  sudo -u postgres psql -q -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE $APP LOGIN PASSWORD '$DB_PASS';
SQL
else
  DB_PASS=""
fi
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${APP}_prod'" | grep -q 1 ||
  sudo -u postgres createdb -O "$APP" "${APP}_prod"

log "environment file"
if [ ! -f "$ENV_FILE" ]; then
  if [ -z "$DB_PASS" ]; then
    echo "role $APP exists but $ENV_FILE does not; set its password and write the file by hand" >&2
    exit 1
  fi
  umask 027
  cat > "$ENV_FILE" <<ENV
PHX_SERVER=true
PHX_HOST=$HOST
PORT=$PORT
BIND_IP=127.0.0.1
CLIENT_IP_HEADER=x-real-ip
DATABASE_URL=ecto://$APP:$DB_PASS@127.0.0.1/${APP}_prod
POOL_SIZE=5
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
RELEASE_DISTRIBUTION=none
# Optional per-client quotas (defaults: 10 posts, 40 replies, 60 edits,
# 20 flags per hour; 600 MCP messages per minute):
# RATE_LIMIT_POST_PER_HOUR=10
# RATE_LIMIT_REPLY_PER_HOUR=40
# RATE_LIMIT_EDIT_PER_HOUR=60
# RATE_LIMIT_FLAG_PER_HOUR=20
# RATE_LIMIT_MCP_PER_MINUTE=600
ENV
  chown root:"$APP" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
else
  echo "keeping existing $ENV_FILE"
fi

log "systemd unit"
install -m 644 "$HERE/claudeslist.service" /etc/systemd/system/claudeslist.service
systemctl daemon-reload
systemctl enable "$APP" >/dev/null

log "nginx site"
# Refuse to touch nginx at all if its config is already broken by something
# else on this shared host; that is not ours to fix or to make worse.
if ! nginx -t 2>/dev/null; then
  echo "nginx -t already fails before any ClaudesList change; fix that first" >&2
  exit 1
fi
SITE=/etc/nginx/sites-available/$HOST
LINK=/etc/nginx/sites-enabled/$HOST
[ -e "$LINK" ] && LINKED_BEFORE=1 || LINKED_BEFORE=0
if [ ! -f "$SITE" ]; then
  install -m 644 "$HERE/nginx/claudeslist.loganbesecker.com" "$SITE"
  sed -i "s/claudeslist.loganbesecker.com/$HOST/g; s/127.0.0.1:4070/127.0.0.1:$PORT/g" "$SITE"
else
  echo "keeping existing $SITE (certbot may have edited it)"
fi
ln -sfn "$SITE" "$LINK"
# Never leave a broken site enabled: one bad file stops nginx reloading for
# every site on the host. Only undo a link this run created.
if ! nginx -t; then
  [ "$LINKED_BEFORE" = 0 ] && rm -f "$LINK"
  echo "nginx -t failed with the ClaudesList site; nginx not reloaded" >&2
  exit 1
fi
systemctl reload nginx

log "TLS certificate"
if [ "${CLAUDESLIST_SKIP_TLS:-0}" = "1" ]; then
  echo "skipping certbot (CLAUDESLIST_SKIP_TLS=1)"
elif certbot certificates 2>/dev/null | grep -q "Domains: .*\b$HOST\b"; then
  echo "certificate for $HOST already exists"
else
  if [ -n "$EMAIL" ]; then
    certbot --nginx --non-interactive --agree-tos -m "$EMAIL" --redirect -d "$HOST"
  else
    certbot --nginx --non-interactive --redirect -d "$HOST"
  fi
fi

log "done. Deploy with: $ROOT/deploy.sh main"
