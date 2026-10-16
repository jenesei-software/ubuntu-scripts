# Cloudflare HTTP Module

The `cloudflare-http/` module restricts Docker-published HTTP/HTTPS ports to Cloudflare's network, so
a service behind Cloudflare cannot be reached by talking to the origin address directly. It is
isolated from other modules and reads only `cloudflare-http/.env` by default.

## What It Does

`setup-cloudflare-http.sh`:

* checks the platform, the required commands and that Docker is running
* detects the internet-facing interface from the default route when `WAN_INTERFACE` is empty
* installs the rule script as `/usr/local/sbin/<SERVICE_NAME>.sh`
* writes `/etc/systemd/system/<SERVICE_NAME>.service` and, by default, a weekly refresh timer
* runs the rule script once and verifies that the jump rule and the chain are in place

`apply-rules.sh`:

* fetches Cloudflare's IPv4 and IPv6 ranges and caches them under `/var/lib/cf-only-http`
* rebuilds one chain (`CHAIN_NAME`, `CF_ONLY_HTTP` by default): a `RETURN` per allowed range, then a
  final `DROP`
* inserts or verifies its own jump rule at the top of `DOCKER-USER` for the configured TCP ports

`check-setup.sh` verifies the platform, the commands, the interface, the chains, the cached ranges
(compared with the live list) and the systemd units, without changing anything. It exits nonzero when
a required check fails.

## Why DOCKER-USER and Not UFW

Docker publishes container ports with rules of its own, and those rules are evaluated before UFW, so
an ordinary UFW rule cannot filter them. `DOCKER-USER` is consulted first from `FORWARD` and is never
rewritten by Docker, which is why the rule lives there.

The module never enables UFW and never touches the rest of `DOCKER-USER`: it owns exactly one chain
and one jump rule.

## Why the Origin Must Be Closed

Country and consent headers (`cf-ipcountry` and friends) are read from the request without checking
its source. If the origin stays reachable by address, any client can send `CF-IPCountry: US`, skip
the CDN and take the geo decision into its own hands. Restricting the origin to Cloudflare's ranges is
what makes a CDN-based decision trustworthy.

## Requirements

* Ubuntu 24.04 with root access
* Docker installed and running (`DOCKER-USER` must exist)
* outbound HTTPS access to `www.cloudflare.com` on first run, and a cached copy afterwards
* the domain already pointed at the server through Cloudflare, proxied

## Files

```text
cloudflare-http/
|-- env.example
|-- apply-rules.sh
|-- setup-cloudflare-http.sh
`-- check-setup.sh
```

## Prepare Env

An env file is optional: sensible defaults are used without one, and the interface is detected
automatically.

```bash
cd ~/ubuntu-scripts/cloudflare-http
cp env.example .env
nano .env
```

Variables:

```env
WAN_INTERFACE=
HTTP_PORTS=80,443
CHAIN_NAME=CF_ONLY_HTTP
ALLOW_EXTRA_CIDRS=
SERVICE_NAME=cf-only-http
REFRESH_TIMER=true
```

* `WAN_INTERFACE` — interface that faces the internet. Empty detects it from the default route.
* `HTTP_PORTS` — Docker-published TCP ports to restrict.
* `CHAIN_NAME` — the chain this module creates and owns.
* `ALLOW_EXTRA_CIDRS` — extra CIDRs allowed on top of Cloudflare, comma separated. Opt-in and risky:
  every CIDR here reaches the origin without the CDN, which defeats the point of a geo decision.
* `SERVICE_NAME` — base name for the unit, the helper script and the timer.
* `REFRESH_TIMER` — install a weekly timer that refreshes the ranges. The list is refreshed on every
  boot and on every setup run either way.

## Run

From `~/ubuntu-scripts/cloudflare-http`:

```bash
bash setup-cloudflare-http.sh
bash check-setup.sh
```

A different env file can be passed explicitly:

```bash
bash setup-cloudflare-http.sh /root/cloudflare-http.production.env
bash check-setup.sh /root/cloudflare-http.production.env
```

## Verify

```bash
systemctl status cf-only-http.service --no-pager
systemctl list-timers cf-only-http.timer --no-pager
iptables -nL DOCKER-USER
iptables -nL CF_ONLY_HTTP
```

From an **outside** host — never from the server itself, because traffic to its own public address
does not pass through `DOCKER-USER`:

```bash
# through the CDN: works, and the country header arrives
curl -sI https://example.com/ | grep -i -E 'cf-ray|set-cookie'

# straight to the origin address: must time out
curl -sI -k --max-time 8 https://ORIGIN_IP/ ; echo "exit=$?"
```

## Rollback

Stop and remove everything the module owns:

```bash
systemctl disable --now cf-only-http.service cf-only-http.timer
rm -f /etc/systemd/system/cf-only-http.service /etc/systemd/system/cf-only-http.timer
systemctl daemon-reload

iptables -D DOCKER-USER -i eth0 -p tcp -m multiport --dports 80,443 -j CF_ONLY_HTTP
iptables -F CF_ONLY_HTTP
iptables -X CF_ONLY_HTTP

ip6tables -D DOCKER-USER -i eth0 -p tcp -m multiport --dports 80,443 -j CF_ONLY_HTTP
ip6tables -F CF_ONLY_HTTP
ip6tables -X CF_ONLY_HTTP

rm -f /usr/local/sbin/cf-only-http.sh
rm -rf /var/lib/cf-only-http
```

Docker containers, networks and data are not touched.

## Important Notes

* Certificate renewal keeps working: Let's Encrypt resolves the domain to the CDN and validates from
  Cloudflare addresses, which are allowed. If a proxy in front of the origin is ever removed, remove
  this module first, otherwise the origin becomes unreachable for everybody.
* If the range download fails and there is no cached copy, the rule script exits without changing
  anything; the previous rules stay in place until a reboot.
* IPv6 is restricted only when Docker manages an IPv6 `DOCKER-USER` chain. Otherwise the script warns
  and leaves IPv6 alone.
* `ALLOW_EXTRA_CIDRS` is meant for a short debugging window, not for production.

## Upstream References

* [Cloudflare IP ranges](https://www.cloudflare.com/ips/)
* [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
* [`iptables-extensions`: `multiport`](https://manpages.debian.org/bookworm/iptables/iptables-extensions.8.en.html)
