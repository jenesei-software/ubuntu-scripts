# Ghost on Coolify

This page describes a Ghost deployment managed by Coolify: Ghost and MySQL run as one Docker Compose
service on a Coolify node, and Coolify's Traefik proxy terminates TLS. It also covers the migration
from the native installation created by the `ghost/` module.

Use this path when the server is already a Coolify node. The `ghost/` module owns public `80/443`
through system Caddy and must not run on that host; see [ghost.md](ghost.md).

## Target Architecture

```text
Internet
  |
  | 80/tcp, 443/tcp
  v
Traefik (coolify-proxy, managed by Coolify)
  |
  | http://ghost-<uuid>:2368
  v
ghost container  --->  ghost-db container (MySQL 8)
  |                        |
  v                        v
/opt/ghost/content     /opt/ghost/mysql
```

Ghost and MySQL use bind mounts, so the data survives redeploys and the database can be restored with
ordinary file and SQL tools.

## Prerequisites

* a server added to Coolify with Docker installed and the proxy running (see
  [coolify-node.md](coolify-node.md));
* DNS control for the blog hostname;
* root SSH access to the old server and to the new node;
* a target Ghost image that is not older than the database being imported.

## Inventory the Source

On the old server:

```bash
sudo -u ghostadmin bash -lc 'cd /var/www/ghost && ghost --version'
mysql -N -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables GROUP BY 1;"
du -sh /var/www/ghost/content
```

Record the Ghost version, the database name, and the content size. The image tag in the Compose
definition must not be older than the recorded Ghost version.

## Export

```bash
sudo install -d -m 700 /root/ghost-migration
sudo mysqldump --single-transaction --quick --routines --triggers --no-tablespaces \
  --default-character-set=utf8mb4 ghost_prod | gzip -9 | sudo tee /root/ghost-migration/ghost_prod.sql.gz >/dev/null
sudo tar -C /var/www/ghost/content --exclude='./logs' -czf /root/ghost-migration/content.tar.gz .
sudo sha256sum /root/ghost-migration/*
```

`content/logs` is excluded: Ghost writes its own logs, and the old ones are not needed. Copy both
files to the new node and compare the checksums before restoring.

`mysqldump` does not include MySQL users, so the database user is recreated by the container
environment variables instead of being restored from the dump.

## Prepare the Node

```bash
sudo install -d -m 755 /opt/ghost /opt/ghost/content
sudo install -d -m 700 /opt/ghost/mysql
sudo tar -C /opt/ghost/content -xzf /root/ghost-migration/content.tar.gz
sudo chown -R 1000:1000 /opt/ghost/content
sudo find /opt/ghost/content -type d -exec chmod 755 {} +
sudo find /opt/ghost/content -type f -exec chmod 644 {} +
```

The official `ghost` image runs as the `node` user with uid `1000`; the `mysql` image uses uid `999`.
Leave the database directory to the MySQL entrypoint, which fixes its ownership on first start.

## Compose Definition

Create the resource with **+ New → Docker Compose → Deploy** in the target project, then paste:

```yaml
services:
  ghost:
    image: ghost:6.45.0
    restart: unless-stopped
    environment:
      url: https://blog.example.com
      NODE_ENV: production
      database__client: mysql
      database__connection__host: ghost-db
      database__connection__port: 3306
      database__connection__user: ghost
      database__connection__password: ${GHOST_DB_PASSWORD}
      database__connection__database: ghost_prod
      mail__transport: Direct
      security__staffDeviceVerification: 'false'
      SERVICE_FQDN_GHOST_2368: blog.example.com
    volumes:
      - /opt/ghost/content:/var/lib/ghost/content
    depends_on:
      ghost-db:
        condition: service_healthy
    networks:
      - coolify
      - internal
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:2368/',{redirect:'manual'}).then(r=>process.exit(r.status<400?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
  ghost-db:
    image: mysql:8.0
    restart: unless-stopped
    command: '--innodb-buffer-pool-size=128M'
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost_prod
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ${GHOST_DB_PASSWORD}
    volumes:
      - /opt/ghost/mysql:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 60s
networks:
  coolify:
    external: true
  internal:
    driver: bridge
```

Notes:

* `SERVICE_FQDN_GHOST_2368` is Coolify's domain variable. It creates the Traefik router for port
  `2368` and makes the hostname appear under **Domains**. Set the domain through the Domains tab
  instead of editing the value by hand.
* `${GHOST_DB_PASSWORD}` and `${MYSQL_ROOT_PASSWORD}` make Coolify create empty environment
  variables. Fill them under **Environment Variables** before the first deploy.
* `url` is Ghost's canonical URL, not a proxy setting. Change it together with the domain.
* The Ghost health check uses `node` because it is always present in the image, and it accepts the
  `301` redirect Ghost returns for a non-canonical `Host`. A `wget` check would follow that redirect
  to the public HTTPS address and time out.
* `mysqladmin` reads the password from the container environment through `$$`, which Compose
  collapses to a single `$` before the shell sees it.

## Restore Before the First Start

Deploying against an empty database makes Ghost create a fresh schema and seed data. Restore the dump
first, using a temporary MySQL container against the same data directory:

```bash
DB_PW='value-from-GHOST_DB_PASSWORD'
ROOT_PW='value-from-MYSQL_ROOT_PASSWORD'
sudo docker run -d --name ghost-db-restore \
  -e MYSQL_ROOT_PASSWORD="$ROOT_PW" \
  -e MYSQL_DATABASE=ghost_prod \
  -e MYSQL_USER=ghost \
  -e MYSQL_PASSWORD="$DB_PW" \
  -v /opt/ghost/mysql:/var/lib/mysql \
  mysql:8.0

sudo docker logs -f ghost-db-restore   # stop following after "Ready for start up"

zcat /root/ghost-migration/ghost_prod.sql.gz | sudo docker exec -i ghost-db-restore \
  sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ghost_prod'

sudo docker exec ghost-db-restore \
  sh -c 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM ghost_prod.posts;"'

sudo docker rm -f ghost-db-restore
```

The row count must match the source. If it does not, the rest of the migration will only produce an
empty site with the right theme.

## Domains and DNS

1. Add `blog.example.com` under **Domains** with protocol `https` and internal port `2368`.
2. Apply the configuration change (the header shows **Changes pending** until the containers are
   recreated).
3. Point the DNS record at the node **before** the first HTTPS request, and lower the TTL in advance.
4. The certificate is requested on the first HTTPS connection. Check the attempt with
   `docker logs --since 2m coolify-proxy 2>&1 | grep -i acme`.

If the challenge fails because the old record was still active, correct the record and run
`docker restart coolify-proxy`: Traefik does not retry a failed order immediately.

## Verify

```bash
curl -sI https://blog.example.com/
curl -s https://blog.example.com/ | grep -o '<title>[^<]*</title>'
curl -sI https://blog.example.com/ghost/
curl -sI https://blog.example.com/rss/
curl -sI https://blog.example.com/sitemap.xml
curl -sI https://blog.example.com/ghost/api/admin/site/     # 401 without a key
```

Local check that does not depend on public DNS:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
  --resolve blog.example.com:443:127.0.0.1 https://blog.example.com/
```

The Admin API key of an existing GitHub integration survives the database import, so publishing
workflows that post to `https://blog.example.com/ghost/api/admin/...` keep working as long as the
hostname does not change.

## Root-Domain Redirect

If the apex domain must redirect to the blog, add a second service to the same Compose definition:
Traefik cannot express a cross-host redirect from the Domains tab alone. The service, the Caddyfile,
and the `REDIRECT_TO` variable are documented in
[coolify.md#cross-domain-redirects](coolify.md#cross-domain-redirects). Add `example.com` and
`www.example.com` under **Domains** for that service with internal port `80`.

## Cutover

1. Restore and verify through `--resolve` while the old server still serves the domain.
2. Switch the DNS records.
3. Request the certificate, then verify the pages, the feed, the sitemap, and the Admin API.
4. Stop the old instance: `sudo systemctl disable --now ghost_<name>`.
5. Keep the old database and `content` directory until the new installation has run for a few days.

## Rollback

```bash
sudo systemctl enable --now ghost_<name>
```

Then point DNS back to the old server. The old installation was only stopped, never modified, so it
returns with its own data and certificate.

## Known Pitfalls

* **`503` right after a redeploy** — Traefik removes containers marked `unhealthy` from the load
  balancer, so the proxy answers instead of the application. Check
  `docker inspect <container> --format '{{json .State.Health}}'`.
* **Certificate not issued** — the DNS record must exist before the challenge; a failed order is
  retried only after `docker restart coolify-proxy`.
* **Ghost redirects to the old domain** — `url` in the container environment and the site URL in
  Ghost Admin are independent of the proxy configuration.
* **Caddy health endpoint never matches** — `redir` runs before `respond`; use `handle` blocks.
* **Permissions** — content must belong to uid `1000`, otherwise Ghost cannot write uploads and
  installed themes.
* **Mail** — `mail__transport: Direct` sends from the node's IP. If the provider blocks port `25`,
  configure an SMTP transport before enabling members or newsletters.
* **ActivityPub errors at startup** — Ghost fetches its own `url`; the errors disappear once DNS
  points at the new server.

## Upstream References

* [Ghost: Ubuntu installation](https://docs.ghost.org/install/ubuntu)
* [Ghost: configuration](https://docs.ghost.org/config)
* [Coolify: Docker Compose](https://coolify.io/docs/applications/builds/docker-compose)
* [Coolify: health checks](https://coolify.io/docs/applications/configuration/health-checks)
