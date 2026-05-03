# `containerized/` — directory reference

This directory implements the work-machine setup. **For step-by-step
install and use, read [`../docs/work-machine.md`](../docs/work-machine.md).**
This file is a reference for what each piece in here does, useful when
you're poking at the implementation.

```
containerized/
├── README.md              ← you are here (reference)
├── agent-runner/          image built locally as gascity-agent-runner:claude
│   ├── Dockerfile         debian-slim + nodejs + Claude Code via npm
│   └── entrypoint.sh      validates env contract, drops to agent user, execs CLI
├── shim/
│   ├── gc-docker-runner   bash; argv[0] picks agent, builds docker run, forwards stdio + signals
│   ├── gc-docker          user-facing wrapper: prepends shim dir to PATH, execs gc
│   └── config.example.toml image map, network mode, limits
├── install.sh             docker check → image build → shim + wrapper install → verify
├── uninstall.sh           reverse install.sh (preserves image, config, logs)
└── verify.sh              7 isolation probes from spec §8
```

---

## How an agent invocation flows

```
You type:        gc-docker supervisor run
                     │
                     │  prepends ~/.local/bin/gascity-shims to its OWN PATH
                     ▼  exec gc supervisor run
gc-supervisor   ─►   runtime provider
                     │
                     │  exec("claude", …)  — supervisor inherits the wrapper's PATH
                     ▼
~/.local/bin/gascity-shims/claude  (symlink → gc-docker-runner)
                     │
                     │  reads ~/.config/gascity-docker-runner/config.toml,
                     │  builds docker run with /work bind, --read-only,
                     │  --cap-drop ALL, --user 1000:1000, etc.,
                     ▼  forwards stdio + signals
docker container: gascity-agent-runner:claude
   /work     = the rig worktree (rw)
   /tmp      = tmpfs
   ~/.cache  = tmpfs
   no host SSH keys, no AWS creds, no docker socket
```

Your interactive shell never sees the shim — only `gc-docker`'s child
processes do.

---

## Hard rules for the shim's `docker run` flags

Do **not** relax any of these without re-reading the
[spec §4](../docs/containerizing-gascity-for-local-use-spec.md#4-container-invocation-rules):

- Never mount `$HOME`, `~/.aws`, `~/.ssh`, `~/.config` (other than
  what's explicitly in the env whitelist).
- Never mount `/var/run/docker.sock`. Docker-in-Docker = root on host.
- Never add `--privileged`, `--cap-add`, `--device`, `--pid=host`,
  `--net=host`, `--ipc=host`.
- Never drop `--cap-drop=ALL` or `--security-opt=no-new-privileges`.
- Never drop `--user 1000:1000`.
- Never drop the rootfs `--read-only` flag.

If a probe in `verify.sh` fails after a change here, that's a security
regression — fix the change, not the test.

---

## Configuration

`install.sh` drops a default at `~/.config/gascity-docker-runner/config.toml`.

| Section | Key | Purpose |
|---|---|---|
| `image` | `claude` | Image used when the shim is invoked as `claude`. Defaults to local `gascity-agent-runner:claude`. Pin to a digest once you push to a registry. |
| `network` | `mode` | Docker network. `bridge` (default) gives full internet — fine for v1, swap to a custom allowlist network when v2 lands. |
| `limits` | `memory`, `cpus`, `pids_limit`, `timeout` | Per-container resource caps. `timeout` (e.g. `30m`) hard-kills the container. |

Override location per-invocation via `GC_DOCKER_RUNNER_CONFIG=/path/to/cfg`.

---

## v1 limitations (tracked for v2)

- No egress allowlist — uses Docker's default bridge with full internet
  reachability. Spec §6 outlines a dnsmasq + iptables approach.
- No GitHub App token minting — `GH_TOKEN` is forwarded as-is from the
  host environment if set. Spec §5 calls for fresh per-session tokens.
- No per-rig override TOML (`.gc-runner.toml` in the rig root) yet.
- One image per agent (`claude` only). Building `codex` / `gemini`
  images is one Dockerfile each under `agent-runner/`.

---

## Reference

- [Step-by-step setup + daily use](../docs/work-machine.md)
- [Architecture spec](../docs/containerizing-gascity-for-local-use-spec.md)
