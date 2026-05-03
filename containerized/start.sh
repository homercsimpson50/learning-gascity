#!/usr/bin/env bash
# start.sh — one-shot bring-up for the Gas City container.
#
# Usage:
#   ./start.sh              # build (if needed), bring up, smoke test
#   ./start.sh --rebuild    # force rebuild before bringing up
#   ./start.sh --shell      # after bring-up, drop into a shell inside
#   ./start.sh --down       # stop everything (preserves volumes)
#   ./start.sh --wipe       # stop + delete all volumes (full reset)

set -euo pipefail
cd "$(dirname "$0")"

REBUILD=0
SHELL_AFTER=0
ACTION=up

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --shell)   SHELL_AFTER=1 ;;
    --down)    ACTION=down ;;
    --wipe)    ACTION=wipe ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2 ;;
  esac
done

# --- Down / wipe paths ---
if [ "$ACTION" = down ]; then
  echo "→ stopping (volumes preserved)"
  docker compose down
  exit 0
fi

if [ "$ACTION" = wipe ]; then
  echo "→ stopping AND wiping all volumes (state will be lost)"
  read -p "  type 'yes' to confirm: " confirm
  [ "$confirm" = yes ] || { echo "aborted"; exit 1; }
  docker compose down -v
  exit 0
fi

# --- Up path ---
if [ ! -f .env ]; then
  echo "→ creating .env from .env.example"
  cp .env.example .env
  echo "  ⚠ edit .env to set GIT_USER and GIT_EMAIL, then re-run"
  exit 1
fi

# Sanity: warn if user left placeholder identity
if grep -qE '^GIT_USER=Your Name|^GIT_EMAIL=you@example.com' .env; then
  echo "  ⚠ .env still has placeholder GIT_USER / GIT_EMAIL"
  echo "    git commits inside the container will be authored as 'Your Name'."
  read -p "  proceed anyway? (y/N) " proceed
  [ "${proceed:-N}" = y ] || exit 1
fi

# Build only if image missing or --rebuild
if [ "$REBUILD" -eq 1 ]; then
  echo "→ rebuilding image"
  docker compose build --no-cache
elif ! docker image inspect gascity:latest >/dev/null 2>&1; then
  echo "→ building image (first run, takes ~3-5 min)"
  docker compose build
else
  echo "→ image present, skipping build (use --rebuild to force)"
fi

echo "→ starting container"
docker compose up -d

# Wait for the container to be healthy enough that gc responds.
echo -n "→ waiting for gc to be ready"
for _ in $(seq 1 30); do
  if docker compose exec -T gascity gc version >/dev/null 2>&1; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 2
done

# Smoke test
echo
echo "→ smoke test"
docker compose exec -T gascity gc version | sed 's/^/   gc version: /'
docker compose exec -T gascity gc doctor 2>&1 | tail -1 | sed 's/^/   gc doctor:  /'

# Quick credential-sync check (informational, not fatal)
if docker compose exec -T gascity test -f /home/agent/.claude/settings.json; then
  echo "   claude:     host config synced ✓"
else
  echo "   claude:     no host config detected (run 'claude' inside the container to log in)"
fi

cat <<'EOF'

→ ready. Common next steps:
   docker compose exec gascity bash             # shell inside the container
   docker compose exec gascity gc cities        # list cities
   docker compose exec gascity gc bd ready      # show ready beads
   docker compose logs -f gascity               # tail container logs
   ./start.sh --down                            # stop (keep state)
   ./start.sh --wipe                            # stop + reset state
EOF

if [ "$SHELL_AFTER" -eq 1 ]; then
  echo
  echo "→ dropping into shell"
  exec docker compose exec gascity bash
fi
