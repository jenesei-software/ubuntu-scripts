# Repository Guidelines

## Scope

This repository contains independent Bash modules for provisioning and checking Ubuntu 24.04 servers. Treat every module as production infrastructure code: a failed or partially applied change can affect SSH access, the firewall, persistent data, or public services.

These rules apply to the whole repository. A more specific `AGENTS.md` may add requirements for its subtree, but must not weaken the safety rules here.

## Repository Layout

- Keep each install target in its own top-level directory.
- A service module normally contains `env.example`, `setup-<module>.sh`, and `check-setup.sh`.
- Keep user-facing documentation in `wiki/<module>.md`; do not add a module README without a concrete need.
- Update the root `README.md` structure, module list, and firewall summary when adding or changing a module.
- A module owns its `.env`. Never read a root `.env` or another module's `.env` unless the dependency is explicit and documented.
- Never commit `.env` files, generated secrets, private keys, logs, reports, backups, or runtime data.

## Bash Baseline

- Use Bash with `#!/usr/bin/env bash` and `set -Eeuo pipefail`.
- Resolve the module directory from `${BASH_SOURCE[0]}` and make default paths independent of the caller's working directory.
- Quote expansions unless intentional word splitting is documented and locally disabled for ShellCheck.
- Prefer `[[ ... ]]`, `printf`, arrays, `local` variables, and functions with one clear responsibility.
- Use uppercase names for exported/configuration variables and lowercase names for local variables.
- Keep files LF-only and finish every text file with a newline.
- Use timestamped `INFO`, `WARN`, `ERROR`, `OK`, and `SECTION` messages consistent with existing scripts. Never enable `set -x` around secrets.

## Environment Files and Input Validation

- Accept an optional env-file path as the first positional argument; otherwise use `<module>/.env`.
- Resolve relative env paths from either the current directory or the module directory, matching existing module behavior.
- Reset every supported variable before sourcing the env file so inherited process variables cannot silently become configuration.
- Source env files with `set -a` / `set +a` and a narrow `# shellcheck disable=SC1090` comment.
- List every supported variable in `env.example`, with safe or obviously replaceable values and comments for risky options.
- Validate all required values before the first material change. Validate booleans, ports, URLs/domains, usernames, paths, image tags/versions, CIDRs, and mutually dependent variables.
- Reject placeholder credentials such as `change_me` before deployment. Do not print secret values in logs or diagnostic output.
- Use explicit opt-in variables for destructive operations, secret rotation, overwriting user configuration, or accepting known conflicts.

## Setup Script Requirements

- Require root only when the operations need it and give an exact rerun command in the error.
- Run preflight checks before mutation: supported Ubuntu release/architecture, commands, CPU/RAM/disk requirements, occupied ports, existing services, and configuration conflicts.
- Make setup scripts idempotent and safe to rerun for repair or upgrade. Preserve persistent data and stable secrets by default.
- Install only required packages and use noninteractive package-manager settings where prompts are possible.
- Use official HTTPS repositories and vendor documentation. Install repository signing keys into dedicated keyrings; do not use deprecated `apt-key`.
- Do not pipe a remote installer directly into a privileged shell. Download it to a temporary file over HTTPS, fail on download errors, validate basic provenance, execute it explicitly, and clean it up with a trap. Pin a version where repeatability matters; document when `latest` is intentional.
- Back up user-managed files before replacement. For shared files such as Caddyfile, edit a uniquely marked managed block, validate the complete result, and restore the backup on failure.
- Write sensitive files with restrictive modes. Use temporary files plus an atomic move for generated configuration when practical.
- Prefer dedicated unprivileged service users. If a vendor requires root, document the exception and its security implications.
- Validate generated Docker Compose configuration before `up -d`; wait with a finite timeout and fail on unhealthy, exited, or dead containers.
- Do not stop, remove, prune, or recreate unrelated containers, services, networks, firewall rules, or data.
- End with the service URL, a non-secret next action, and useful diagnostic/log commands.

## Networking, Firewall, and Reverse Proxy

- Bind application ports to `127.0.0.1` unless direct public access is required and documented.
- Document every public TCP/UDP port and whether it is opened by the module, UFW, Docker, a reverse proxy, or a provider firewall.
- Do not enable UFW from an isolated service module. It may add idempotent rules, but the base `ubuntu/` module owns initial firewall enablement and SSH safety.
- Remember that Docker-published ports can bypass ordinary UFW filtering. Do not claim UFW alone restricts a Docker port; document provider-firewall or `DOCKER-USER`/equivalent requirements.
- Detect conflicts on shared ports before installation. Never silently replace another service's listener or Caddy virtual host.
- Validate Caddy configuration before reload and restore the previous file if validation or reload fails.

## Check Script Requirements

- Keep `check-setup.sh` non-destructive and safe to run repeatedly. It must not install, restart, rewrite, pull, upgrade, or delete anything.
- Use the same env resolution and defaults as the setup script, without exposing secrets.
- Check relevant OS/resources, packages/repositories, systemd services, service users and permissions, Docker/Compose, generated files, containers and health, listening addresses, local HTTP health, reverse-proxy configuration, and firewall state.
- Separate results into readable sections. Distinguish actionable errors from warnings and informational state.
- Continue through independent checks when possible, summarize the result, and exit nonzero when required health checks fail.
- Network checks must use bounded connection and total timeouts.

## Documentation and Verification

- Base third-party installation behavior on current official documentation and source files. Record upstream URLs and important compatibility constraints in the module wiki.
- Document prerequisites, `.env` preparation, install, first-login security, verification, upgrade, backup, logs, firewall/provider rules, known conflicts, and rollback/uninstall cautions.
- Before handing off a change, run at least:
  - `bash -n` for every changed shell script;
  - `shellcheck` for every changed shell script when available;
  - a review for CRLF, placeholders, leaked secrets, unquoted expansions, and destructive commands;
  - a diff check covering `README.md`, `env.example`, and `wiki/<module>.md` for a new module.
- Do not run provisioning scripts against the workstation or a real server merely to test syntax. Use a disposable Ubuntu 24.04 host for integration testing.

## Git Conventions

- Preserve unrelated user changes in a dirty worktree.
- Follow `.github/instructions/commit-rules.md`: one Conventional Commit-style message in the form `<type>(scope): <imperative description>`, with a first line no longer than 72 characters.
