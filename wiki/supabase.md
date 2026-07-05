# Supabase Module

The `supabase/` module installs one self-hosted Supabase project behind Caddy.

It uses Supabase's official Docker Compose deployment: Kong API gateway, Studio, Auth, PostgREST, Realtime, Storage, imgproxy, Postgres Meta, Edge Functions, Postgres, and Supavisor. The module keeps public HTTP/HTTPS traffic in Caddy and binds Supabase's published ports to localhost by default.

References:

* https://supabase.com/docs/guides/self-hosting/docker
* https://supabase.com/docs/guides/self-hosting/self-hosted-proxy-https

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* Caddy installed on the server if `SUPABASE_CONFIGURE_CADDY=true`
* a domain name already pointed to the server
* the ability to open `80/tcp` and `443/tcp` from the internet
* at least **4 GB RAM**, with **8 GB+ RAM** recommended
* at least **40 GB SSD**, with **80 GB+ SSD** recommended

Docker is installed automatically by this module when it is missing.

## Files

```text
supabase/
|-- env.example
|-- setup-supabase.sh
`-- check-setup.sh
```

## Architecture

```text
Internet
  |
  | 80/tcp, 443/tcp
  v
Caddy
  |
  | reverse_proxy SUPABASE_BIND_IP:SUPABASE_KONG_HTTP_PORT
  v
Kong API gateway
  |
  +-- Studio
  +-- Auth
  +-- PostgREST
  +-- Realtime
  +-- Storage
  +-- Edge Functions
  |
  v
Postgres and Supavisor
```

Default local upstream:

```env
SUPABASE_BIND_IP=127.0.0.1
SUPABASE_KONG_HTTP_PORT=8000
```

Default local Postgres pooler ports:

```env
SUPABASE_DB_BIND_IP=127.0.0.1
SUPABASE_POSTGRES_PORT=5432
SUPABASE_POOLER_TRANSACTION_PORT=6543
```

## Prepare Env

Run this module from the same root-owned checkout where you downloaded `ubuntu-scripts`.

Clone the repository on the server:

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone https://github.com/jenesei-software/ubuntu-scripts.git ubuntu-scripts
cd ~/ubuntu-scripts
```

Prepare the Supabase env:

```bash
cd ~/ubuntu-scripts/supabase
cp env.example .env
nano .env
```

Required values:

```env
SUPABASE_URL=https://supabase.example.com
SUPABASE_SITE_URL=https://app.example.com
SUPABASE_DASHBOARD_USERNAME=supabase
SUPABASE_DASHBOARD_PASSWORD=changeMeDashboardPassword
SUPABASE_POSTGRES_PASSWORD=changeMePostgresPassword
SUPABASE_POOLER_TENANT_ID=default
```

`SUPABASE_URL` is the public URL for Studio and APIs.
`SUPABASE_SITE_URL` is the default frontend redirect URL used by Auth.
Use only letters and digits in `SUPABASE_DASHBOARD_PASSWORD` and `SUPABASE_POSTGRES_PASSWORD`.
Do not leave unquoted spaces in `supabase/.env`, because the setup script loads it as a shell file.

If you do not have a frontend app yet, set:

```env
SUPABASE_SITE_URL=https://supabase.example.com
```

## Run

Install Caddy first:

```bash
cd ~/ubuntu-scripts/caddy
bash setup-caddy.sh
```

Then run Supabase setup:

```bash
cd ~/ubuntu-scripts/supabase
bash setup-supabase.sh
```

The script copies the official Supabase Docker project to:

```text
/opt/supabase
```

It then generates Supabase secrets with:

```text
utils/generate-keys.sh
utils/add-new-auth-keys.sh
```

After setup, open `SUPABASE_URL` in the browser and log in to Studio with `SUPABASE_DASHBOARD_USERNAME` and `SUPABASE_DASHBOARD_PASSWORD`.

## Service User

By default, Supabase Docker Compose operations run as root. To run them as a dedicated Linux user, set:

```env
SUPABASE_SYSTEM_USER=supabaseadmin
SUPABASE_SYSTEM_PASSWORD=changeMeSystemPassword
SUPABASE_SYSTEM_SSH_PUB=""
```

When `SUPABASE_SYSTEM_USER` is set, setup creates or reuses that user, adds it to the `docker` group, gives it `/opt/supabase`, and runs Supabase Docker operations as that user.

Details: [service-users.md](service-users.md)

## Domain Conflict Behavior

If `SUPABASE_URL` uses a domain that is already present in `/etc/caddy/Caddyfile`:

* If the existing block already points to `SUPABASE_BIND_IP:SUPABASE_KONG_HTTP_PORT`, it is kept.
* If the existing block points somewhere else, setup asks whether to replace it.
* If the block was created by this module, it is updated safely between managed markers.

For unattended runs, choose the behavior in `supabase/.env`:

```env
SUPABASE_CADDY_OVERWRITE_DOMAIN=ask
```

Allowed values:

* `ask` - ask before replacing the occupied domain
* `true` - replace without asking
* `false` - stop without replacing

Set this to skip Caddy changes:

```env
SUPABASE_CONFIGURE_CADDY=false
```

Use that only when you plan to configure Caddy manually.

## Verify

```bash
cd ~/ubuntu-scripts/supabase
bash check-setup.sh
```

The check script verifies:

* Docker and Docker Compose
* Docker apt repository files
* Supabase project files in `/opt/supabase`
* generated publishable and secret API keys
* Supabase containers
* Kong local Auth endpoint
* Supavisor local ports
* Caddyfile validation
* Caddy reverse proxy target
* UFW HTTP/HTTPS rules

## Useful Commands

View service status:

```bash
cd /opt/supabase
sh run.sh status
```

View logs:

```bash
cd /opt/supabase
sh run.sh logs
```

View logs for one service:

```bash
cd /opt/supabase
sh run.sh logs auth
```

Show generated credentials:

```bash
cd /opt/supabase
sh run.sh secrets
```

Restart Supabase:

```bash
cd /opt/supabase
sh run.sh restart
```

Recreate one service after config changes:

```bash
cd /opt/supabase
sh run.sh recreate auth
```

Stop Supabase:

```bash
cd /opt/supabase
sh run.sh stop
```

## Email Auth

Supabase Auth can create users without SMTP only when email confirmation is disabled or when you handle confirmation another way.

For production email auth, configure real SMTP values in `supabase/.env` before setup:

```env
SUPABASE_SMTP_ADMIN_EMAIL=admin@example.com
SUPABASE_SMTP_HOST=smtp.example.com
SUPABASE_SMTP_PORT=465
SUPABASE_SMTP_USER=your_smtp_user
SUPABASE_SMTP_PASS=your_smtp_password
SUPABASE_SMTP_SENDER_NAME=YourApp
SUPABASE_ENABLE_EMAIL_AUTOCONFIRM=false
```

For a private test instance, you can temporarily set:

```env
SUPABASE_ENABLE_EMAIL_AUTOCONFIRM=true
```

## Logs And Analytics

Supabase does not enable Logs and Analytics in the default Docker Compose stack. To enable the optional Logflare and Vector services during setup:

```env
SUPABASE_ENABLE_LOGS=true
```

These services increase memory usage.

## Connecting Applications

The app usually needs:

```text
SUPABASE_PUBLIC_URL
SUPABASE_PUBLISHABLE_KEY
```

Show generated values on the server:

```bash
cd /opt/supabase
sh run.sh secrets
```

Never expose `SUPABASE_SECRET_KEY` in frontend code.

## Open Ports

Supabase itself listens locally and does not need a public firewall rule.

Public ports are handled by the Caddy module:

* `80/tcp`
* `443/tcp`

Keep these values local unless you explicitly want to expose database pooler access:

```env
SUPABASE_DB_BIND_IP=127.0.0.1
SUPABASE_POSTGRES_PORT=5432
SUPABASE_POOLER_TRANSACTION_PORT=6543
```
