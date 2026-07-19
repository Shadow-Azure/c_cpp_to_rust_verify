# Design: `aliyun-server` user-level skill

**Date**: 2026-07-19
**Status**: Approved
**Topic**: Extract the Aliyun remote-server info & operation methods into a user-level Claude skill.

## Goal

Centralize access knowledge for the Aliyun server (`47.98.144.243`) — currently duplicated in `c_cpp_to_rust/CLAUDE.md` and `c_cpp_to_rust_verify/CLAUDE.md` — into one user-level skill at `~/.claude/skills/aliyun-server/`, so Claude can manage the server from any project, not just the two c_cpp_to_rust repos.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Command delivery | Skill bundles its own copy of `server-access.sh` | Self-contained; preserves subcommand UX; works from any directory |
| Content scope | Machine-ops core only | User-level skill should hold generic server-ops knowledge, not project-specific config |
| Project `CLAUDE.md` files | Left untouched | Skill is additive; project files stay self-contained |

## File layout

```
~/.claude/skills/aliyun-server/
├── SKILL.md
└── server-access.sh    # copy of c_cpp_to_rust_verify/scripts/server-access.sh, chmod +x
```

## SKILL.md

**Frontmatter**
- `name`: aliyun-server
- `description`: triggers on server/runner management intent (check or restart runners, Docker status, server resources, runner logs); names the server IP, the bundled script, and the `ALIYUN_SERVER_PASSWORD` mechanism
- `allowed-tools`: Bash

**Body sections**
1. **Prerequisites** — `$ALIYUN_SERVER_PASSWORD` set (in `~/.zshrc`); `sshpass` installed (with brew command)
2. **Server info** — IP `47.98.144.243`, user `root`, Ubuntu 24.04.4 LTS, SSH password auth
3. **Runners on this server** — table: runner name, repo, systemd service name, install dir (needed for `restart`/`logs`)
4. **Use the bundled script** — `~/.claude/skills/aliyun-server/server-access.sh <command>` + subcommand list (`connection` / `status` / `restart [all|verify|c2rust]` / `docker` / `resources` / `logs [verify|c2rust]`)
5. **Raw fallback** — `sshpass -p "$ALIYUN_SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no root@47.98.144.243 "<cmd>"` with 1–2 examples (`systemctl status github-runner`)
6. **Sync note** — states this script is a verbatim copy of `c_cpp_to_rust_verify/scripts/server-access.sh`; sync manually if the original changes

## Script copy

- Copy `c_cpp_to_rust_verify/scripts/server-access.sh` **verbatim** into the skill dir, then update only the leading comment header to reflect the new location (it's the user-level copy).
- `chmod +x`.
- The script is already portable — no project-specific paths, only depends on `$ALIYUN_SERVER_PASSWORD` + `sshpass`. No other changes needed.

## Out of scope (stays in project `CLAUDE.md`)

GitHub API commands, pipeline config (`evaluate.yml`/`release.yml`), evaluation criteria, version history, Docker image build details. These are bound to specific repo names / environment IDs / model names and are project-specific.

## Security

- Password is **never** written into the skill — only the env-var name `$ALIYUN_SERVER_PASSWORD` is referenced (matches the existing script and `~/.zshrc` setup).
- No secrets in SKILL.md or the script.

## Verification

- `bash ~/.claude/skills/aliyun-server/server-access.sh help` prints usage.
- With `$ALIYUN_SERVER_PASSWORD` sourced, `... connection` successfully SSHes and prints `uname -a`.
- Claude auto-triggers the skill when asked (in a non-c_cpp_to_rust project) to check runner status.
