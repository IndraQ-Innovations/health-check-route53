<div align="center">

<img src="https://YOUR-LOGO-LINK-HERE/indraq-logo.png" alt="IndraQ Innovations Logo" width="320">

# IndraQ Route 53 Health Check

### Tiny Docker health endpoint + AWS Route 53 firewall automation

![Docker](https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white)
![AWS Route 53](https://img.shields.io/badge/AWS-Route%2053-FF9900?logo=amazonwebservices&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Linux-Ubuntu-E95420?logo=ubuntu&logoColor=white)
![Firewall](https://img.shields.io/badge/Firewall-Script%20v2.1.0-0F766E)

</div>

---

> [!IMPORTANT]
> This README is written for a person with **zero knowledge** of Docker, Route 53, public/private IPs, Linux firewalls, `iptables`, `ipset`, CIDR, or systemd.

## What does this project do?

It creates a tiny health URL:

```text
http://SERVER-IP:8877/health
```

When the health service is alive it returns:

```text
OK
```

with HTTP status:

```text
200 OK
```

AWS Route 53 can call this endpoint to decide whether your server is reachable.

The included firewall installer also downloads AWS's current Route 53 health-check IPv4 ranges and explicitly allows those health checkers through Docker's firewall path.

On a hardened Docker host, all unmatched traffic continues to the server's existing Docker firewall policy.

---

# Architecture

```text
AWS Route 53
     |
     | HTTP TCP :8877
     v
YOUR PUBLIC IP
     |
     | Router / NAT / Port Forward
     v
SERVER PRIVATE IP :8877
     |
     v
DOCKER-USER
     |
     +--> INDRAQ-R53-HEALTH
     |       |
     |       +--> AWS Route53 IP? ------> ACCEPT
     |       +--> Trusted test IP? -----> ACCEPT
     |       +--> Anything else --------> RETURN
     |
     v
Existing Docker hardening
     |
     v
healthcheck container
     |
     v
GET /health -> 200 OK
```

---

# Repository files

```text
indraq-route53-healthcheck/
├── .env.example
├── .gitignore
├── Dockerfile
├── docker-compose.yml
├── server.js
├── health-check.sh
└── README.md
```

### `server.js`
Minimal Node.js web server. Only `/health` returns `200 OK`; unknown paths return `404`.

### `Dockerfile`
Builds the health-check image from `node:22-alpine` and runs Node as the non-root `node` user.

### `docker-compose.yml`
Runs the container on port `8877` with a read-only filesystem, no extra Linux capabilities, a PID limit, RAM limit and CPU limit.

### `.env.example`
Template for the server's private/LAN IP. The real `.env` is ignored by Git.

### `health-check.sh`
Installs and maintains the AWS Route 53 IP allowlist, Docker firewall chain, saved config, systemd service and automatic refresh timer.

---

# Beginner glossary

## Public IP
Internet-facing IP of your site/router/server.

Example:

```text
110.225.255.65
```

AWS Route 53 connects to this address.

## Private/LAN IP
Address used inside your local network.

Example:

```text
192.168.10.101
```

This is the address you normally put in `.env`.

## Port
Think of the IP as a building and the port as one numbered door.

This project uses:

```text
8877
```

## `/health`
The small web path that returns `OK` when the health service is alive.

## Docker
Runs the health service in an isolated container.

## Port forwarding / NAT
If your router owns the public IP, it must forward:

```text
PUBLIC_IP:8877 -> SERVER_PRIVATE_IP:8877
```

## Source IP
Where a connection is coming **from**.

## Destination IP
Where a connection is going **to**.

## `/32`
For IPv4, `/32` means exactly one IP.

Example:

```text
223.181.16.84/32
```

means only `223.181.16.84`.

---

# Before installation

You need:

- Linux server
- Docker Engine installed
- Docker Compose available
- `sudo` access
- server private/LAN IPv4
- public IPv4 or router NAT/port-forwarding
- AWS Route 53 access
- an existing downstream Docker hardening policy if you expect non-AWS internet traffic to be blocked

> [!WARNING]
> The Route 53 chain itself does **not** install a global catch-all DROP rule. Unmatched traffic is returned to your existing Docker policy so this installer does not accidentally break unrelated production containers.

---

# Step 1 — clone the repository

```bash
git clone https://github.com/YOUR-ORG/indraq-route53-healthcheck.git
cd indraq-route53-healthcheck
```

---

# Step 2 — configure the private/LAN IP

Copy the template:

```bash
cp .env.example .env
```

Find the server's IPv4 addresses:

```bash
ip -4 addr
```

Edit:

```bash
nano .env
```

Example:

```text
HEALTHCHECK_BIND_IP=192.168.10.101
```

This is the **server's private/LAN IP**, not its public internet IP.

---

# Step 3 — start the Docker health service

```bash
docker compose up -d --build --force-recreate
```

What this builds:

```text
node:22-alpine
      |
      +--> server.js
      |
      v
healthcheck Docker image
      |
      v
healthcheck container
      |
      v
PRIVATE_IP:8877/health
```

Check it:

```bash
docker ps --filter name=healthcheck
```

---

# Step 4 — test locally

Replace the example IP with your server's private IP:

```bash
curl -i http://192.168.10.101:8877/health
```

Expected:

```text
HTTP/1.1 200 OK
...

OK
```

Do not continue until this works.

---

# Step 5 — configure router/NAT

If the Linux server is behind a router, forward **TCP**:

```text
PUBLIC_IP:8877 -> SERVER_PRIVATE_IP:8877
```

Example:

```text
110.225.255.65:8877 -> 192.168.10.101:8877
```

Do not create a UDP rule; Route 53's HTTP health check uses TCP.

---

# Step 6 — run the firewall installer

```bash
chmod +x health-check.sh
sudo ./health-check.sh
```

The installer checks/installs the helper tools it needs, verifies Docker and the healthcheck container, downloads AWS Route 53 IP ranges, creates firewall rules and installs persistence.

---

# Public IP vs trusted test source IP

This is the most common point of confusion.

Suppose:

```text
Server public IP:               110.225.255.65
Your external testing public IP: 223.181.16.84
```

The connection is:

```text
FROM 223.181.16.84
TO   110.225.255.65:8877
```

Therefore:

```text
PUBLIC_IP = 110.225.255.65
```

and:

```text
TEST_SOURCE_CIDRS = 223.181.16.84/32
```

Do **not** enter the server's own public IP as the trusted source. Script v2.1.0 detects that mistake and rejects it.

If you do not need manual external testing, just press Enter at the trusted-source prompt.

---

# What the installer creates

Saved config:

```text
/etc/indraq/route53-healthcheck.conf
```

Installed script copy:

```text
/usr/local/sbin/indraq-route53-healthcheck-firewall
```

systemd service:

```text
indraq-route53-healthcheck-firewall.service
```

systemd timer:

```text
indraq-route53-healthcheck-firewall.timer
```

Firewall chain:

```text
INDRAQ-R53-HEALTH
```

AWS IPv4 ipset:

```text
route53_healthchecks
```

---

# Step 7 — create the Route 53 health check

Recommended AWS values:

| Setting | Value |
|---|---|
| Endpoint | IP address |
| IP address | Your public IPv4 |
| Protocol | HTTP |
| Port | `8877` |
| Path | `/health` |
| Request interval | `30 seconds` |

Example:

```text
IP:       110.225.255.65
Protocol: HTTP
Port:     8877
Path:     /health
```

---

# Verify everything

## Docker

```bash
docker ps --filter name=healthcheck
```

## Local health

```bash
curl -i http://YOUR_PRIVATE_IP:8877/health
```

## DOCKER-USER order

```bash
sudo iptables -L DOCKER-USER -n -v --line-numbers
```

On a hardened IndraQ server it may look like:

```text
1  INDRAQ-R53-HEALTH
2  INDRAQ-DOCKER-GUARD
```

## Route 53 chain

```bash
sudo iptables -L INDRAQ-R53-HEALTH -n -v --line-numbers
```

Expected structure:

```text
AWS Route53 health checkers       ACCEPT
Trusted test source(s)            ACCEPT  # only if configured
Return unmatched traffic          RETURN
```

## AWS ranges

```bash
sudo ipset list route53_healthchecks
```

## Saved configuration

```bash
cat /etc/indraq/route53-healthcheck.conf
```

Example:

```text
PORT="8877"
CONTAINER_NAME="healthcheck"
CONTAINER_PORT="8877"
HOST_IP="192.168.10.101"
PUBLIC_IP="110.225.255.65"
WAN_IF="enp19s0"
TEST_SOURCE_CIDRS="223.181.16.84/32"
```

## Timer

```bash
systemctl status indraq-route53-healthcheck-firewall.timer --no-pager
```

## Watch AWS packets arrive

```bash
watch -n 2 'sudo iptables -L INDRAQ-R53-HEALTH -n -v --line-numbers'
```

When Route 53 is checking the endpoint, the packet counter on the AWS ACCEPT rule should increase.

Exit with `Ctrl+C`.

---

# Supported firewall-script commands

## Install/update

```bash
sudo ./health-check.sh
```

First run = interactive wizard.

If saved config exists, it reuses it.

## Apply saved config

```bash
sudo ./health-check.sh --apply
```

Loads `/etc/indraq/route53-healthcheck.conf`, refreshes AWS ranges and rebuilds the firewall rules.

## Uninstall

```bash
sudo ./health-check.sh --uninstall
```

Removes this project's Route 53 firewall chain, ipset, systemd service/timer, saved config and installed script copy.

It leaves Docker, the healthcheck container and your existing Docker hardening untouched.

## Reset

```bash
sudo ./health-check.sh --reset
```

Removes this Route 53 setup and immediately starts a fresh interactive installation.

## Help

```bash
./health-check.sh --help
```

## Version

```bash
./health-check.sh --version
```

Expected:

```text
2.1.0
```

---

# Change your trusted test IP later

Edit:

```bash
sudo nano /etc/indraq/route53-healthcheck.conf
```

Example:

```text
TEST_SOURCE_CIDRS="223.181.16.84/32"
```

Then apply:

```bash
sudo ./health-check.sh --apply
```

or:

```bash
sudo systemctl restart indraq-route53-healthcheck-firewall.service
```

Verify:

```bash
sudo iptables -L INDRAQ-R53-HEALTH -n -v --line-numbers
```

---

# Automatic AWS range updates

The systemd timer refreshes the official AWS `ROUTE53_HEALTHCHECKS` IPv4 ranges approximately once per day.

See its schedule:

```bash
systemctl list-timers --all | grep indraq-route53
```

---

# Troubleshooting

## Local `/health` fails

```bash
docker ps --filter name=healthcheck
docker logs healthcheck
```

Recreate:

```bash
docker compose up -d --build --force-recreate
```

## Private IP works but public IP does not

Watch packets:

```bash
sudo tcpdump -ni any tcp port 8877
```

Then test from an external internet connection.

No packets = investigate router/NAT/ISP/public IP.

Packets arrive = investigate Linux/Docker firewall rules.

## Public-IP test from the same office fails

Your router may not support or may not have NAT loopback/hairpin NAT configured.

Use another internet connection, for example mobile data with Wi-Fi off.

## AWS works but your browser times out

That may be correct. AWS has an explicit allow rule. Your browser only gets one if its public source IP is configured as a trusted source.

---

# Security notes

The Docker health service intentionally has:

- no database;
- no user login;
- no file uploads;
- no application secrets;
- no npm dependencies beyond Node itself;
- non-root execution;
- read-only container filesystem;
- all Linux capabilities dropped;
- `no-new-privileges`;
- PID, CPU and memory limits.

The health response contains only:

```text
OK
```

---

# Multiple servers

For every server/site:

```text
1. Clone repo
2. cp .env.example .env
3. Put that server's LAN IP in .env
4. docker compose up -d --build --force-recreate
5. Verify /health locally
6. Forward TCP 8877 on the router
7. Run the firewall installer
8. Enter that site's public IP
9. Create Route 53 health check
10. Verify AWS packet counters
```

---

# Updating an existing server from GitHub

```bash
cd /path/to/indraq-route53-healthcheck
git pull
```

Update Docker if the Docker files changed:

```bash
docker compose up -d --build --force-recreate
```

Update/reinstall the firewall script copy:

```bash
sudo ./health-check.sh
```

---

# Maintainer

<div align="center">

<img src="https://YOUR-LOGO-LINK-HERE/indraq-logo.png" alt="IndraQ Innovations Logo" width="220">

### IndraQ Innovations Private Limited

Replace the dummy logo and repository links with your actual public URLs.

</div>
