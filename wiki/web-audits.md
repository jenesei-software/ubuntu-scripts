# Web Audits Module

The `web-audits/` module runs website performance and quality audits with Lighthouse CI and sitespeed.io.

References:

* https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/getting-started.md
* https://googlechrome.github.io/lighthouse-ci/docs/configuration.html
* https://www.sitespeed.io/documentation/sitespeed.io/installation/
* https://www.sitespeed.io/documentation/sitespeed.io/docker/

## Files

```text
web-audits/
|-- env.example
|-- build-reports-dashboard.sh
|-- run-web-audit.sh
`-- check-setup.sh
```

## Run

Interactive mode:

```bash
cd ~/ubuntu-scripts/web-audits
bash run-web-audit.sh
```

Run it as your normal SSH user. The script asks for `sudo` only when it needs to install packages, manage Docker, or clean up Docker after a sitespeed.io run.

## Configuration

Create a local config before changing defaults:

```bash
cd ~/ubuntu-scripts-web-audits/web-audits
cp env.example .env
nano .env
```

`env.example` is only a template from Git. The scripts do not load it automatically. Runtime settings are loaded from `web-audits/.env`, or from a custom `.env` file passed as the first argument:

```bash
bash run-web-audit.sh .env https://example.com lighthouse
```

If `.env` is missing, the scripts use built-in defaults from `run-web-audit.sh`.

## Running Without Sudo

The audit itself can run without `sudo` when the server is already prepared.

For Lighthouse CI without `sudo`, the user needs:

* write access to `web-audits/` for local tools and reports
* `node` and `npm` already installed
* `google-chrome-stable` installed in Linux; `chromium` also works if it is already installed
* `jq`, `zip`, `tar`, and `curl` already installed

Preferred Chrome package:

```bash
sudo apt install -y google-chrome-stable
```

If the Google Chrome apt repository is not configured yet, run `run-web-audit.sh` once with `sudo` rights or ask an admin to install Chrome. The script configures the Google Chrome apt repository and installs `google-chrome-stable` automatically when it has permission.

Lighthouse CI CLI is module-local: `run-web-audit.sh` uses `web-audits/.tools/lhci/node_modules/.bin/lhci` and installs it there when it is missing. Global `lhci` installations are ignored for reproducible runs.

If Node.js is installed through Unix nvm, the scripts try to source `~/.nvm/nvm.sh` before checking `node` and `npm`.

For sitespeed.io without `sudo`, the user needs:

* Docker already installed
* Docker service already running
* access to Docker without sudo, for example membership in the `docker` group
* write access to `web-audits/reports/`

One-time Docker group setup by an admin:

```bash
sudo usermod -aG docker ubuntu
```

Then log out and log back in, or run:

```bash
newgrp docker
```

Check:

```bash
docker info
```

If `docker info` works without `sudo`, sitespeed.io can run without `sudo`.

Important: membership in the `docker` group is effectively root-level access on the host. Treat that user as an admin user.

Non-interactive mode:

```bash
cd ~/ubuntu-scripts/web-audits
bash run-web-audit.sh https://example.com all
```

With the default `.env` file, no extra argument is needed. With a custom env file:

```bash
bash run-web-audit.sh .env https://example.com lighthouse
```

Test types:

* `all`
* `lighthouse`
* `sitespeed`

If the URL does not include a protocol, the script prepends `https://`.

## Sparse Checkout

You can keep only this module on a server and still use `git pull` by cloning the repository with sparse checkout:

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone --filter=blob:none --sparse https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts-web-audits
cd ubuntu-scripts-web-audits
git sparse-checkout set web-audits wiki
```

Run:

```bash
cd ~/ubuntu-scripts-web-audits/web-audits
bash run-web-audit.sh https://example.com all
```

Update later:

```bash
cd ~/ubuntu-scripts-web-audits
git pull
```

This works because sparse checkout still keeps the Git repository metadata. A downloaded zip of only `web-audits/` cannot use `git pull`.

## Dependencies

The script installs missing dependencies through `sudo` when needed.

Lighthouse CI dependencies:

* Node.js
* Google Chrome stable
* `@lhci/cli`

sitespeed.io dependencies:

* Docker Engine
* Docker Compose plugin
* `sitespeedio/sitespeed.io:<tag>`

The sitespeed.io image is pinned in `web-audits/.env` because changing image tags can change browser versions and report results.

The sitespeed.io container is started as a one-shot container with `--rm`, a unique name, and labels for this module. If the script is interrupted, it stops that container. If Docker was inactive before the audit and the script started Docker only for this run, Docker is stopped again after the report is written. If Docker was already active, it is left alone so other services on the server keep running.

Before pulling or running sitespeed.io, the script checks free disk space on the Docker/containerd filesystem. The default minimum is `8GB`; tune it with `WEB_AUDIT_SITESPEED_MIN_FREE_GB`.

## Report Layout

Default:

```text
web-audits/reports/<site>/<timestamp>/
```

Inside a full run:

```text
<timestamp>/
|-- lighthouse-ci/
|   |-- lighthouserc.json
|   `-- reports/
|       |-- manifest.json
|       |-- *.report.html
|       `-- *.report.json
|-- sitespeed/
|   `-- sitespeed-result/
|-- logs/
|   |-- lighthouse-ci.log
|   `-- sitespeed.log
|-- metadata.json
`-- summary.txt
```

If `WEB_AUDIT_CREATE_ZIP=true`, the script also creates:

```text
web-audits/reports/<site>/<timestamp>.zip
```

## Aggregate Report

Build one dashboard from all saved report folders:

```bash
cd ~/ubuntu-scripts-web-audits/web-audits
bash build-reports-dashboard.sh
```

The default input directory is `web-audits/reports`. You can pass a custom folder with reports:

```bash
bash build-reports-dashboard.sh /path/to/web-audits-reports
```

You can also choose a custom output folder:

```bash
bash build-reports-dashboard.sh /path/to/web-audits-reports /path/to/output/web-audits-dashboard
```

The script writes:

```text
aggregate-reports/<timestamp>/
|-- index.html
|-- summary.txt
`-- summary.json
```

`index.html` is the main dashboard. It contains overall charts, latest results by domain, performance trend by domain, per-server sections, and a full run table. The per-server grouping uses `metadata.json` values from `auditSource.hostname` and `auditSource.publicIp`.

`summary.txt` contains the same key results in plain text for terminal review. `summary.json` contains normalized data for later processing.

The aggregate report needs only Node.js. It does not use Docker and does not need `sudo`.

## Env

Copy this from `env.example` into `.env` and edit `.env`:

```env
WEB_AUDIT_RESULTS_DIR=reports
WEB_AUDIT_DEFAULT_TEST=all
WEB_AUDIT_NODE_MAJOR=22
WEB_AUDIT_CHROME_PATH=""
WEB_AUDIT_LHCI_VERSION=latest
WEB_AUDIT_LHCI_RUNS=3
WEB_AUDIT_LHCI_CHROME_FLAGS="--no-sandbox --disable-dev-shm-usage --disable-gpu --disable-setuid-sandbox"
WEB_AUDIT_LHCI_TIMEOUT=10m
WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD=45000
WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP=30000
WEB_AUDIT_SITESPEED_IMAGE=sitespeedio/sitespeed.io:41.3.3
WEB_AUDIT_SITESPEED_BROWSER=chrome
WEB_AUDIT_SITESPEED_RUNS=3
WEB_AUDIT_SITESPEED_CONNECTIVITY=native
WEB_AUDIT_SITESPEED_DOCKER_SHM_SIZE=2g
WEB_AUDIT_SITESPEED_MIN_FREE_GB=8
WEB_AUDIT_SITESPEED_TIMEOUT=30m
WEB_AUDIT_SITESPEED_EXTRA_ARGS=""
WEB_AUDIT_CREATE_ZIP=true
WEB_AUDIT_STOP_DOCKER_AFTER_RUN=true
```

## Timeouts

One Lighthouse pass should not run indefinitely. The module uses two layers of protection:

* `WEB_AUDIT_LHCI_MAX_WAIT_FOR_LOAD` and `WEB_AUDIT_LHCI_MAX_WAIT_FOR_FCP` are passed into Lighthouse settings in milliseconds.
* `WEB_AUDIT_LHCI_TIMEOUT` wraps each individual Lighthouse run and the `lhci upload` command. With `WEB_AUDIT_LHCI_RUNS=3` and `WEB_AUDIT_LHCI_TIMEOUT=10m`, every run gets its own 10 minute limit.
* Before running Lighthouse, the script starts Chrome in headless mode with a 30 second smoke test.
* During `lhci collect`, the script forces temporary Chrome and LHCI files into a Linux `/tmp/web-audits-lhci-*` directory. This avoids WSL creating `C:\Users\...` profile directories inside the report folder.

The script runs `lhci collect` one Lighthouse pass at a time and uses LHCI additive mode after the first pass, so all runs are saved into the same report set. After collection, it requires the expected number of saved LHR files before running `lhci upload`. If Lighthouse times out and saves too few reports, the run fails immediately instead of creating an empty `manifest.json`.

If the log stops around `Run #1...` and then shows `Unable to connect to Chrome`, check that the server is using Linux Node.js and Linux Chrome, not Windows `node.exe` or Windows Chrome from WSL. The report log usually exposes this through paths like `/mnt/c/Users/.../lighthouse...`.

Check:

```bash
which node
which npm
which google-chrome-stable || which google-chrome || which chromium
bash check-setup.sh
```

If needed, force the Linux executable in `web-audits/.env`:

```env
WEB_AUDIT_CHROME_PATH=/usr/bin/google-chrome-stable
```

If a run is already stuck, press `Ctrl+C`. If the terminal does not return, inspect and stop the related processes:

```bash
ps aux | grep -E 'lhci|lighthouse|chrome' | grep -v grep
```

Then stop only the relevant process IDs:

```bash
kill PID
```

## Metadata

Each run writes `metadata.json` with the target URL, run status, tool settings, and source server data:

```json
{
  "auditSource": {
    "hostname": "server.example",
    "publicIp": "203.0.113.10",
    "localIps": "10.0.0.5 172.17.0.1"
  }
}
```

`auditSource.publicIp` is resolved through a short external IP check. If that check is unavailable, the value is written as `unknown` and the audit continues.

## Download To Windows

Download one archive from Windows PowerShell. Use the SSH user and exact archive path printed in `summary.txt`:

```powershell
scp SSH_USER@SERVER_IP:/path/to/ubuntu-scripts/web-audits/reports/example.com/20260623-153000.zip C:\Users\YOUR_USER\Downloads\
```

With a custom SSH port:

```powershell
scp -P PORT SSH_USER@SERVER_IP:/path/to/ubuntu-scripts/web-audits/reports/example.com/20260623-153000.zip C:\Users\YOUR_USER\Downloads\
```

Download all reports:

```powershell
scp -r SSH_USER@SERVER_IP:/path/to/ubuntu-scripts/web-audits/reports C:\Users\YOUR_USER\Downloads\web-audits-reports
```

Build an aggregate dashboard from the downloaded reports through WSL:

```bash
cd /mnt/e/git-library/jenesei-software/ubuntu-scripts/web-audits
bash build-reports-dashboard.sh /mnt/c/Users/YOUR_USER/Downloads/web-audits-reports
```

WinSCP path:

```text
/path/to/ubuntu-scripts/web-audits/reports
```

## Check

```bash
cd ~/ubuntu-scripts/web-audits
bash check-setup.sh
```

The check script verifies installed commands, apt repository files, the configured sitespeed.io Docker image, and recent report archives.
