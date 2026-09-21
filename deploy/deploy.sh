#!/usr/bin/env bash
# Build and roll out a ClaudesList release on the server. Run as root:
#
#     /opt/claudeslist/deploy.sh [git-ref]      # default: main
#
# The build runs as the unprivileged `claudeslist-build` user with a clean
# environment (no production secrets), migrations run as the `claudeslist`
# runtime user, and root only flips the `current` symlink and restarts the
# unit. If the new release fails its health check, `current` is pointed back
# at the previous release automatically.
set -euo pipefail
umask 022

APP=claudeslist
BUILD_USER=claudeslist-build
REF="${1:-main}"
REPO="${CLAUDESLIST_REPO:-https://github.com/lbesecker195/Claudeslist.git}"
ROOT=/opt/claudeslist
SRC="$ROOT/src"
RELEASES="$ROOT/releases"
BUILD_HOME="$ROOT/build-home"
ENV_FILE=/etc/claudeslist/claudeslist.env
KEEP=5
SAFE_PATH=/usr/local/bin:/usr/bin:/bin

log() { printf '\n==> %s\n' "$*"; }
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -r "$ENV_FILE" ] || { echo "missing $ENV_FILE (run bootstrap.sh first)" >&2; exit 1; }
id "$BUILD_USER" >/dev/null 2>&1 || { echo "missing $BUILD_USER user (run bootstrap.sh)" >&2; exit 1; }

# Only non-secret values are read here; the env file is never exported.
PORT="$(env_value PORT)"; PORT="${PORT:-4070}"
PHX_HOST="$(env_value PHX_HOST)"
[ -n "$PHX_HOST" ] || { echo "PHX_HOST missing from $ENV_FILE" >&2; exit 1; }

as_builder() {
  runuser -u "$BUILD_USER" -- env -i HOME="$BUILD_HOME" PATH="$SAFE_PATH" LANG=C.UTF-8 MIX_ENV=prod "$@"
}

TARGET=""
FLIPPED=0
cleanup() {
  # A build or migration that failed before the flip leaves a partial
  # release directory behind; remove it. Rolled-back releases are kept.
  if [ "$FLIPPED" = 0 ] && [ -n "$TARGET" ] && [ -d "$TARGET" ]; then rm -rf "$TARGET"; fi
  if [ -n "${MIGRATE_TMP:-}" ]; then rm -rf "$MIGRATE_TMP"; fi
}
trap cleanup EXIT

log "fetching $REF"
if [ ! -d "$SRC/.git" ]; then
  as_builder git clone --quiet "$REPO" "$SRC"
fi
as_builder git -C "$SRC" fetch --quiet --tags --force origin
as_builder git -C "$SRC" checkout --quiet --force "origin/$REF" 2>/dev/null ||
  as_builder git -C "$SRC" checkout --quiet --force "$REF"
as_builder git -C "$SRC" clean -fdxq -e deps -e _build
SHA="$(as_builder git -C "$SRC" rev-parse --short HEAD)"
STAMP="$(date -u +%Y%m%d%H%M%S)-$SHA"
TARGET="$RELEASES/$STAMP"

log "building $SHA as $BUILD_USER"
# shellcheck disable=SC2016  # expanded by the inner shell
as_builder bash -c '
  set -euo pipefail
  cd "$1"
  mix local.hex --force --if-missing >/dev/null
  mix local.rebar --force --if-missing >/dev/null
  mix deps.get --only prod
  mix compile
  mix assets.deploy
  mix release --overwrite --path "$2"
' _ "$SRC" "$TARGET"

# Take the finished release away from the build user: from here on root
# (touch, rm, ln) and the runtime user only ever act on a root-owned tree,
# so nothing the build left behind (e.g. a planted symlink) can redirect them.
chown -R --no-dereference root:root "$TARGET"
chmod -R u+rwX,go+rX,go-w "$TARGET"
# The health marker is root's alone; drop anything the build put there.
rm -f "$TARGET/.healthy"

log "migrating as $APP"
MIGRATE_TMP="$(mktemp -d)"
chown "$APP" "$MIGRATE_TMP"
# shellcheck disable=SC2016  # expanded by the inner shell
runuser -u "$APP" -- env -i HOME="$ROOT" PATH="$SAFE_PATH" LANG=C.UTF-8 RELEASE_TMP="$MIGRATE_TMP" \
  bash -c 'set -a; . "$0"; set +a; exec "$1/bin/migrate"' "$ENV_FILE" "$TARGET"

PREVIOUS=""
if [ -L "$ROOT/current" ]; then PREVIOUS="$(readlink -e "$ROOT/current" || true)"; fi

ln -sfn "$TARGET" "$ROOT/current.new"
mv -Tf "$ROOT/current.new" "$ROOT/current"
FLIPPED=1

log "restarting"
# A failed start must fall through to the health check and rollback below.
systemctl restart "$APP" || true

healthy() {
  # Through the real host path: same Host header and scheme nginx sends.
  for _ in $(seq 1 30); do
    if curl -fsS -m 3 -H "Host: $PHX_HOST" -H "X-Forwarded-Proto: https" \
      "http://127.0.0.1:$PORT/api/v1/stats" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! healthy; then
  echo "health check failed" >&2
  journalctl -u "$APP" -n 40 --no-pager >&2 || true

  if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$TARGET" ] && [ -d "$PREVIOUS" ]; then
    log "rolling back to $(basename "$PREVIOUS")"
    ln -sfn "$PREVIOUS" "$ROOT/current.new"
    mv -Tf "$ROOT/current.new" "$ROOT/current"
    systemctl restart "$APP" || true
    if healthy; then
      log "rolled back; $(basename "$PREVIOUS") is serving. Failed build kept at $TARGET"
    else
      echo "ROLLBACK ALSO UNHEALTHY: check journalctl -u $APP" >&2
    fi
  else
    echo "no previous release to roll back to; $APP is down (current -> $STAMP)" >&2
  fi
  exit 1
fi

touch "$TARGET/.healthy"
log "live: $STAMP"

log "pruning (keeping $KEEP healthy releases)"
CURRENT="$(readlink -e "$ROOT/current")"
kept=0
while read -r name; do
  dir="$RELEASES/$name"
  [ "$dir" = "$CURRENT" ] && { kept=$((kept + 1)); continue; }
  if [ -e "$dir/.healthy" ] && [ "$kept" -lt "$KEEP" ]; then
    kept=$((kept + 1))
  else
    rm -rf "${dir:?}"
  fi
done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
