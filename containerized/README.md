# Containerized Gas City

A clean, gascity-only Docker setup. The image is built from the upstream
[gastownhall/gascity](https://github.com/gastownhall/gascity) repo at a
pinned ref — you don't need to clone gascity yourself.

```
containerized/
├── Dockerfile             # multi-stage: clones + builds gascity, runtime image
├── docker-compose.yml     # one-service stack with security defaults
├── docker-entrypoint.sh   # extracted entrypoint (keyring, host-cred sync, gc init)
├── .env.example           # GIT_USER, GIT_EMAIL, GASCITY_REF, …
└── README.md              # you are here
```

---

## Quick start

```bash
cd containerized/
cp .env.example .env
# edit .env so GIT_USER / GIT_EMAIL aren't "TestUser"

docker compose up -d --build
docker compose exec gascity gc version
docker compose exec gascity gc doctor

# add a rig from your host's ~/code (bind-mounted at /city/rigs-host)
docker compose exec gascity bash -c \
    "cd /city/rigs-host/<your-repo> && gc rig add ."

# drop into a shell to drive Gas City
docker compose exec gascity bash
```

To stop:

```bash
docker compose down              # keep volumes (state preserved)
docker compose down -v           # wipe state too
```

---

## How it works

The Dockerfile is two stages:

1. **`builder`** — golang base, `git clone` of `${GASCITY_REPO}` at
   `${GASCITY_REF}`, `make build`. Produces just `gc`.
2. **`runtime`** — `docker/sandbox-templates:claude-code` base + Gas
   City's runtime deps (`tmux`, `jq`, `procps`, `lsof`, `util-linux`,
   `dbus` + `gnome-keyring` + `libsecret-1-0` for Claude Code's libsecret
   credential storage), plus `bd` and `dolt` for the default beads
   provider. The `gc` binary is `COPY --from=builder`ed in.

The container's `CMD` is `gc supervisor run` — the foreground equivalent
of the `gc start` command you'd use on a host (which on the host
registers a launchd / systemd service; pointless inside a container).

The entrypoint (`docker-entrypoint.sh`) does five things on every start:

1. Apply git/dolt config from `GIT_USER` / `GIT_EMAIL` (idempotent).
2. Start D-Bus + GNOME Keyring so Claude Code can persist credentials.
3. Sync host `~/.claude` (read-only mount) into the writable home volume
   so the container inherits your Claude Code login.
4. Sync host `~/.config/gh/hosts.yml` so `git push` from agents works.
5. On first run only: `gc init --provider <GC_PROVIDER> /city`.

---

## Security

Same posture as the gastown reference setup, distilled:

- `cap_drop: [ALL]` plus only `CHOWN`, `SETUID`, `SETGID` for keyring +
  process bookkeeping.
- `no-new-privileges:true` so a compromised process can't `sudo` out.
- `pids: 512`, `memory: 4G`, `cpus: 4` — caps fork bombs and runaway
  agent loops.
- Host SSH keys, AWS credentials, browser profiles, the rest of
  `~/.config` — **not** mounted. Agents physically can't read them.
- Host `~/.claude` and `~/.config/gh` mounted **read-only** at separate
  paths; the entrypoint copies just the files needed into a writable
  volume so the container inherits auth without giving agents write
  access to your host config.
- `IS_SANDBOX=1` is set so Claude Code knows it's running in a sandbox.

---

## Volumes

| Volume | Path in container | Purpose |
|---|---|---|
| `city-workspace` | `/city` | The city scaffold (`city.toml`, `pack.toml`, `.gc/`, agents, formulas, etc.). Lose this and `gc init` re-runs. |
| `dolt-data` | `/city/.dolt-data` | Beads database files. Kept off bind mounts because VirtioFS fsync semantics can corrupt the dolt journal on macOS. |
| `claude-data` | `/home/agent/.claude` | Claude Code credentials, sessions, history. |
| `claude-state` | `/home/agent/.local/state/claude` | Claude runtime state (lockfiles, version pins). |
| `claude-share` | `/home/agent/.local/share/claude` | Claude shared assets (theme picker won't pop on restart). |
| (bind, rw) | `/city/rigs-host` ← `${GCC_CODE_DIR:-~/code}` | Your code; rigs added out of subdirectories. |
| (bind, ro) | `/home/agent/.claude-host` ← `~/.claude` | Read-only Claude config staging. |
| (bind, ro) | `/home/agent/.config/gh-host` ← `~/.config/gh` | Read-only gh CLI staging. |

---

## Knobs

All defaults work. Set in `.env`:

| Variable | Default | Purpose |
|---|---|---|
| `GIT_USER` | `TestUser` | git + dolt user.name (idempotent each start) |
| `GIT_EMAIL` | `test@example.com` | Same for user.email |
| `GC_PROVIDER` | `claude` | Coding-agent runtime registered into the city. Other valid values: `codex`, `gemini`, `cursor`, `copilot`, `amp`, `opencode`, `auggie`, `pi`, `omp` (see `gc init --help`) |
| `GASCITY_REPO` | `https://github.com/gastownhall/gascity.git` | Source repo to build from |
| `GASCITY_REF` | `main` | Tag, branch, or SHA to check out |
| `GASCITY_IMAGE_TAG` | `latest` | Image tag — bump to keep versions side by side |
| `GCC_CODE_DIR` | `~/code` | Host directory bind-mounted at `/city/rigs-host` |

---

## Reproducible builds

To pin to a specific release:

```bash
echo 'GASCITY_REF=v1.0.1'        >> .env
echo 'GASCITY_IMAGE_TAG=v1.0.1'  >> .env
docker compose build
```

Or build from a fork:

```bash
echo 'GASCITY_REPO=https://github.com/<fork>/gascity.git' >> .env
echo 'GASCITY_REF=<branch-or-sha>'                        >> .env
docker compose build
```

---

## Troubleshooting

**`gc start` complains "missing required dependencies"**
The container ships dolt + flock pre-installed; this should not happen
inside the container. If it does, the dolt installer failed during
`docker build` — re-run with `docker compose build --no-cache`.

**`claude` keeps re-prompting for login**
The `claude-data` volume is fresh and your host `~/.claude/.credentials.json`
hasn't been synced. Check it exists on the host first: `ls ~/.claude/`.
If you've never logged in on the host either, run `claude` once
interactively *inside* the container.

**Dolt journal corruption after `docker compose down`**
`dolt-data` should always be on a Docker volume, never on a macOS bind
mount. The compose file already does this — don't change it.

**`gc rig add` says path not found**
Rigs must be added from inside the container against the bind-mounted
path: `/city/rigs-host/<repo>`, not the host path.

**Build fails fetching gascity**
The default `GASCITY_REF` is `main` — if upstream is mid-rewrite, pin to
a release tag in `.env` and rebuild.
