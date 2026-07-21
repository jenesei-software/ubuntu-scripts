# Mailcow

This module installs one pinned Mailcow release on a dedicated Ubuntu 24.04 VPS. Mailcow's web ports bind only to loopback, the existing system Caddy terminates public HTTPS, and the standard SMTP, IMAP, POP3, and ManageSieve ports remain directly reachable.

The Authentik integration uses Mailcow's native Generic-OIDC support. Authentik and Mailcow may, and for this deployment do, run on separate VPS instances.

## Requirements

- a dedicated full VM or bare-metal Ubuntu 24.04 server; LXC, OpenVZ, Virtuozzo, and other container VPS products are unsupported by Mailcow;
- at least 6 GiB RAM plus 1 GiB swap and 20 GiB free disk before storing mail;
- Docker 24+ and Docker Compose 2+; the setup installs them from Docker's official repository when absent;
- Caddy already installed on the Mailcow VPS when `MAILCOW_CONFIGURE_CADDY=true`;
- a static public IP whose provider allows inbound and outbound TCP port 25;
- control of forward DNS and PTR/rDNS;
- no existing mail service on the required ports.

Mailcow is a complete groupware stack, not only an SMTP daemon. For more than a few active users, 8 GiB or more RAM is recommended. `MAILCOW_ALLOW_LOW_RESOURCES=true` bypasses only this repository's preflight check; it does not make an undersized VPS reliable.

## DNS and Cloudflare

For a Mailcow hostname such as `mail.example.com` and mail domain `example.com`, prepare these records:

| Record | Name | Value | Cloudflare mode |
| --- | --- | --- | --- |
| A | `mail` | Mailcow VPS IPv4 | **DNS only** |
| AAAA | `mail` | Mailcow VPS IPv6 | **DNS only**, only when IPv6 works end to end |
| MX | `@` | `10 mail.example.com` | DNS record |
| CNAME | `autodiscover` | `mail.example.com` | **DNS only** |
| CNAME | `autoconfig` | `mail.example.com` | **DNS only** |
| TXT | `@` | start with an appropriate SPF policy, for example `v=spf1 mx -all` | DNS record |
| TXT | `_dmarc` | start with a monitored DMARC policy, for example `v=DMARC1; p=none; rua=mailto:dmarc@example.com` | DNS record |

Set PTR/rDNS for the sending IP to exactly `mail.example.com` at the VPS provider. After adding the domain in Mailcow, publish the DKIM record displayed by its UI. Do not publish an AAAA record while `MAILCOW_ENABLE_IPV6=false` or while IPv6 routing and reverse DNS are incomplete.

The setup deliberately does not rewrite Docker's host-wide IPv6 settings. Leave `MAILCOW_ENABLE_IPV6=false` unless Docker IPv6, routing, the AAAA record, and IPv6 PTR/rDNS have already been configured and tested using Mailcow's official IPv6 guidance.

`mail.example.com` must remain **DNS only** in Cloudflare. The normal Cloudflare proxy carries web traffic, not SMTP, IMAP, POP3, or ManageSieve. A proxied mail hostname resolves to Cloudflare addresses and breaks mail clients and delivery. The separate Authentik hostname, such as `sso.example.com`, may remain Proxied.

If Cloudflare Email Routing is enabled for the same mail domain, remove or replace its MX records before switching delivery to Mailcow; a domain cannot simultaneously direct the same inbound mail to both MX setups.

## Provider firewall

Allow these inbound TCP ports to the Mailcow VPS:

- `25` — server-to-server SMTP;
- `465` — implicit TLS SMTP submission;
- `587` — SMTP submission with STARTTLS;
- `143` and `993` — IMAP and IMAPS;
- `110` and `995` — POP3 and POP3S, if clients need them;
- `4190` — ManageSieve;
- `80` and `443` — Caddy and certificate issuance.

The setup does not enable UFW or rewrite the host firewall. Docker-published ports can bypass ordinary UFW `INPUT` rules, so apply public restrictions in the provider firewall or a carefully managed `DOCKER-USER`/forwarding ruleset. Do not restrict port 25 to your own addresses; other mail servers must be able to reach it.

Confirm that outbound TCP port 25 is not blocked by the VPS provider. A successful installation cannot compensate for blocked outbound SMTP or incorrect reputation/PTR records.

## Install

On the dedicated Mailcow VPS, run the repository's `ubuntu/` and `caddy/` modules first. Then prepare Mailcow:

```bash
cd ~/ubuntu-scripts/mailcow
cp env.example .env
nano .env
chmod 600 .env
sudo bash setup-mailcow.sh
sudo bash check-setup.sh
```

At minimum, replace:

```dotenv
MAILCOW_HOSTNAME=mail.example.com
MAILCOW_MAIL_DOMAINS=example.com
MAILCOW_TIMEZONE=Etc/UTC
MAILCOW_ADDITIONAL_SERVER_NAMES=autodiscover.example.com,autoconfig.example.com
```

`MAILCOW_HOSTNAME` is the server FQDN, not the domain after `@` in every mailbox. `MAILCOW_MAIL_DOMAINS` is a diagnostic list; the setup deliberately does not create mail domains or mailboxes without an administrator reviewing quotas and settings in the UI.

The installation pins the official `2026-07` release and verifies its Git commit before checkout. It uses the official configuration generator without allowing that generator to rewrite Docker's host-wide IPv6 settings, then explicitly applies the loopback reverse-proxy configuration:

```text
HTTP_BIND=127.0.0.1
HTTP_PORT=8080
HTTPS_BIND=127.0.0.1
HTTPS_PORT=8443
HTTP_REDIRECT=n
SKIP_LETS_ENCRYPT=y
```

Mailcow's own ACME client must remain disabled because Caddy owns web certificates. A systemd timer copies Caddy's current certificate and key into Mailcow every 15 minutes and restarts only `postfix-mailcow`, `dovecot-mailcow`, and `nginx-mailcow` when the certificate changes.

If `/opt/mailcow-dockerized` already contains an official Mailcow checkout that was not created by this module, setup stops before changing it. Verify a complete backup, confirm that the local administrator no longer uses Mailcow's public default password, set `MAILCOW_ADOPT_EXISTING=true` for one reviewed run, then return the value to `false`. A configured adopted installation keeps its existing administrator password; an unconfigured adopted checkout receives the same automatic random reset as a fresh module installation.

### First administrator login

A stock Mailcow installation starts with the public default `admin` / `moohoo`. Before exposing a newly installed UI through Caddy, the setup invokes Mailcow's official administrator reset helper, replaces that password with a random 32-character value, and stores it in a root-only file:

```bash
sudo sed -n '1,2p' /etc/mailcow/initial-admin.env
```

Do not paste that output into chats, tickets, or logs. Sign in at:

```text
https://mail.example.com/admin
```

Keep this local super-administrator as the recovery account. Add two-factor authentication in Mailcow after the first login. The Authentik Generic-OIDC integration authenticates mailbox users; it should not replace your only emergency administrator path.

If you later change the local administrator password in Mailcow, `/etc/mailcow/initial-admin.env` is not updated automatically. Update your protected recovery record or remove the stale bootstrap file after the new credential is safely stored in a password manager.

## Initial Mailcow configuration

Before enabling automatic OIDC provisioning:

1. Open **E-Mail > Configuration > Domains** and add every domain from `MAILCOW_MAIL_DOMAINS` with deliberate mailbox and quota limits.
2. Open the domain's DNS diagnostics and publish its DKIM TXT record.
3. Confirm MX, SPF, DKIM, DMARC, PTR/rDNS, and the server hostname.
4. Review the built-in mailbox template named `Default`, or create another template with the intended quota and ACLs.
5. Send and receive test messages before moving production MX records when migrating an existing domain.

## Authentik OIDC integration

The integration requires Mailcow `2025-03` or newer. The pinned release satisfies this requirement.

### 1. Create the Authentik provider

On the separate Authentik VPS, add the Mailcow variables to `~/ubuntu-scripts/authentik/.env`:

```dotenv
AUTHENTIK_URL=https://sso.example.com

MAILCOW_URL=https://mail.example.com
AUTHENTIK_MAILCOW_APP_NAME=Mailcow
AUTHENTIK_MAILCOW_APP_SLUG=mailcow
AUTHENTIK_MAILCOW_CLIENT_ID=mailcow
AUTHENTIK_MAILCOW_TEMPLATE_ATTRIBUTE=default
MAILCOW_OIDC_REDIRECT_URI=https://mail.example.com
```

The redirect URI must equal the public Mailcow URL exactly, without a trailing slash or callback suffix. Run:

```bash
cd ~/ubuntu-scripts/authentik
sudo bash setup-mailcow-oidc.sh
sudo bash check-setup.sh
```

The script idempotently creates or updates:

- an Authentik confidential OAuth2/OpenID provider using Authorization Code flow;
- a strict `https://mail.example.com` redirect URI;
- an Authentik application that launches Mailcow;
- a custom `mailcow_template` scope that returns the value `default`;
- `/opt/authentik/integrations/mailcow-oidc.env` with root-only client settings.

The generated client secret is preserved on normal reruns. Read the values locally on the Authentik VPS:

```bash
sudo sed -n '1,8p' /opt/authentik/integrations/mailcow-oidc.env
```

Do not send or paste the whole file anywhere. It contains `MAILCOW_OIDC_CLIENT_SECRET`.

### 2. Configure Generic-OIDC in Mailcow

Keep the Mailcow local administrator session open. In Mailcow, open **System > Configuration > Access > Identity Provider**, select **Generic-OIDC**, and fill the fields from the generated integration file:

| Mailcow field | Value |
| --- | --- |
| Authorization Endpoint | `MAILCOW_OIDC_AUTHORIZE_URL` |
| Token Endpoint | `MAILCOW_OIDC_TOKEN_URL` |
| User Info Endpoint | `MAILCOW_OIDC_USERINFO_URL` |
| Client ID | `MAILCOW_OIDC_CLIENT_ID` |
| Client Secret | `MAILCOW_OIDC_CLIENT_SECRET` |
| Redirect URL | `MAILCOW_OIDC_REDIRECT_URI` |
| Client Scopes | `openid profile email mailcow_template` |
| Ignore SSL Errors | disabled |

Under **Attribute Mapping**, add:

| Attribute | Mailbox template |
| --- | --- |
| `default` | `Default`, or the intentionally selected template |

Enable **Login provisioning** only when Authentik users should be allowed to create Mailcow mailboxes on first login. Save the configuration and run **Test Connection**.

### 3. Prepare the Authentik user

Mailcow uses the OIDC `email` claim as the mailbox address. The Authentik user's email must therefore be the exact desired address, for example `cyrilstrone@example.com`, and `example.com` must already exist and have free quota in Mailcow.

An Authentik account whose email is an external address such as `user@gmail.com` will not provision a mailbox unless that external domain is hosted in this Mailcow, which it normally is not. Update or create the intended employee account before testing. Add Authentik policy bindings to the Mailcow application if not every Authentik user should be allowed to enter it.

Test a complete login from a private browser window using the **Login with SSO** button. A successful authorization normally causes Mailcow to appear under the user's Authentik connected services; the counter is a result of a completed authorization, not a prerequisite for it.

For an existing Mailcow mailbox, open **E-Mail > Configuration > Mailboxes**, edit the mailbox, and change **Identity Provider** to **Generic-OIDC**. Mailcow retains its previous SQL password if the authentication source is switched back.

Do not enable Mailcow's forced-SSO customization until:

- the connection test succeeds;
- a full private-window login creates or opens the correct mailbox;
- the local Mailcow super-administrator still works;
- the Authentik application is restricted to the intended users.

### External mail clients

OIDC authenticates the Mailcow web UI. Thunderbird, Outlook, mobile clients, SMTP, IMAP, POP3, and ManageSieve do not send an Authentik browser login. After the first successful web login, the user must open **Mailbox Settings > App Passwords**, generate an application password, and use that password in the mail client.

Recommended client endpoints are the Mailcow hostname:

- IMAPS: `mail.example.com:993`;
- SMTP submission: `mail.example.com:587` with STARTTLS, or `465` with implicit TLS;
- ManageSieve: `mail.example.com:4190`.

## Persistent data and secrets

- `/opt/mailcow-dockerized/mailcow.conf`: generated database and service secrets, mode `0600`;
- `/opt/mailcow-dockerized/data/`: Mailcow configuration and certificate targets;
- Docker volumes with MariaDB, Redis, mailboxes, SOGo, Rspamd, and other state;
- `/etc/mailcow/initial-admin.env`: generated initial administrator credentials, mode `0600`;
- `/usr/local/sbin/mailcow-sync-caddy-cert`: certificate deployment script;
- `mailcow-sync-caddy-cert.timer`: periodic certificate synchronization;
- `/opt/authentik/integrations/mailcow-oidc.env` on the Authentik VPS: OIDC client secret and endpoints, mode `0600`.

Back up the Mailcow volumes and `mailcow.conf` together. A mailbox volume without its database and configuration is not a complete recovery set. Use Mailcow's official backup helper and perform a restore test before upgrades.

## Upgrade

Read the Mailcow release notes and create verified backups first. Update `MAILCOW_VERSION` and `MAILCOW_GIT_COMMIT` together to an official release and its exact commit, set:

```dotenv
MAILCOW_UPGRADE_CONFIRMED=true
```

then rerun setup and diagnostics. Return the flag to `false` afterward. The setup refuses to check out a new release when tracked Mailcow source files are modified. For complex or multi-release upgrades, use Mailcow's official `update.sh` workflow and then update the module pin to the installed commit.

Do not delete `/opt/mailcow-dockerized`, Docker volumes, or Mailcow networks as a rollback step. Container recreation does not delete volumes, but manual volume removal permanently destroys mail and database state.

## Diagnostics

```bash
cd ~/ubuntu-scripts/mailcow
sudo bash check-setup.sh

cd /opt/mailcow-dockerized
sudo docker compose ps
sudo docker compose logs --tail=200 nginx-mailcow php-fpm-mailcow
sudo docker compose logs --tail=200 postfix-mailcow dovecot-mailcow

sudo systemctl status caddy
sudo systemctl status mailcow-sync-caddy-cert.timer
sudo systemctl status mailcow-sync-caddy-cert.service
sudo caddy validate --config /etc/caddy/Caddyfile
```

If Caddy has not issued a certificate yet, fix A/AAAA records and inbound `80/443`, then run:

```bash
sudo systemctl start mailcow-sync-caddy-cert.service
```

## Upstream documentation

- [Mailcow system requirements and ports](https://docs.mailcow.email/getstarted/prerequisite-system/)
- [Mailcow installation](https://docs.mailcow.email/getstarted/install/)
- [Mailcow reverse-proxy overview](https://docs.mailcow.email/post_installation/reverse-proxy/r_p/)
- [Mailcow Caddy v2 example and certificate deployment](https://docs.mailcow.email/post_installation/reverse-proxy/r_p-caddy2/)
- [Mailcow Generic-OIDC](https://docs.mailcow.email/manual-guides/mailcow-UI/u_e-mailcow_ui-generic-oidc/)
- [Authentik Mailcow integration](https://docs.goauthentik.io/integrations/services/mailcow/)
- [Official Mailcow source](https://github.com/mailcow/mailcow-dockerized)
