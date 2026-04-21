# Debian 13 Server Reconstruction Bundle

This folder captures the current working host and deployment setup from this server and turns it into a commitable bootstrap bundle. The target state is:

- Debian 13 host
- `tailscaled` enabled, SSH reachable only over `tailscale0`
- `nftables` default-drop input policy
- `80/443` only reachable from Cloudflare IP ranges
- `fail2ban` protecting `sshd` with nftables actions
- rootless Docker running as the `docker` user
- restricted deploy user `gha-ssh`
- app stack under `/home/docker/deploy`
- Caddy proxy in front of `app` and `api`

The live host state was used as the source of truth. A stricter staged `ForceCommand` deploy gateway existed in `/etc/ssh/sshd_config.stage.d`, but it is not currently active, so this bundle reproduces the working live model instead of switching deploy behavior.

## Folder Layout

- `bootstrap-host.sh`: host-level provisioning for a fresh Debian 13 machine
- `configure-stack.sh`: lays down deploy files and starts the app stack once secrets are present
- `templates/`: committed config assets installed by the scripts

## What The Scripts Do

`bootstrap-host.sh`:

- installs required packages
- configures the Tailscale apt source
- creates `docker` and `gha-ssh`
- configures subordinate UID/GID ranges for rootless containers
- installs sysctl, journald, SSH, fail2ban, nftables, and Cloudflare refresh assets
- installs the Supabase direct proxy unit and launcher
- enables `tailscaled`, `nftables`, `fail2ban`, `ssh`, and the Cloudflare refresh timer
- disables rootful Docker services
- enables rootless Docker under the `docker` user

`configure-stack.sh`:

- creates `/home/docker/deploy`
- installs `compose.yaml`, Caddy config, and env files
- copies example env files into real env paths if they do not exist yet
- refreshes the generated Cloudflare allowlists
- optionally logs in to GHCR and starts the stack

## Fresh Host Run Order

1. Copy this folder onto the new Debian 13 host.
2. Run `sudo ./bootstrap-host.sh`.
3. Join the host to Tailscale:
   `sudo tailscale up --ssh`
4. Fill `/etc/default/supabase-direct-proxy`, then enable the proxy:
   `sudo systemctl enable --now supabase-direct-proxy.service`
5. Install the deploy public key into `/home/gha-ssh/.ssh/authorized_keys`.
6. Run `sudo ./configure-stack.sh`.
7. Fill the real env files in `/home/docker/deploy/`.
8. Start the stack:
   `sudo ./configure-stack.sh --start --pull`

## Manual Inputs That Stay Out Of Git

These values are required but should not be committed:

- `/home/gha-ssh/.ssh/authorized_keys`
- `/home/docker/deploy/registry.env`
- `/home/docker/deploy/images.env`
- `/home/docker/deploy/proxy.env`
- `/home/docker/deploy/app.env`
- `/home/docker/deploy/api.env`
- `/etc/default/supabase-direct-proxy`

Current env keys used by the running stack:

- `images.env`
  - `APP_IMAGE`
  - `API_IMAGE`
- `proxy.env`
  - `APP_DOMAIN`
  - `API_DOMAIN`
  - `ACME_EMAIL`
- `registry.env`
  - `GHCR_USERNAME`
  - `GHCR_TOKEN`
- `app.env`
  - `NEXT_PUBLIC_API_URL`
  - `NEXT_PUBLIC_SUPABASE_URL`
  - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
  - `NEXT_PUBLIC_SENTRY_DSN`
- `api.env`
  - `ASPNETCORE_ENVIRONMENT`
  - `DOTNET_ENVIRONMENT`
  - `ConnectionStrings__Database`
  - `Supabase__Url`
  - `Supabase__AnonKey`
  - `Supabase__JwtIssuer`
  - `Supabase__JwtAudiences__0`
  - `Cors__AllowedOriginsCsv`
  - `Sentry__Dsn`
- `/etc/default/supabase-direct-proxy`
  - `SUPABASE_DIRECT_HOST`
  - `SUPABASE_DIRECT_PORT`
  - `SUPABASE_PROXY_LISTEN_ADDR`
  - `SUPABASE_PROXY_LISTEN_PORT`

## GitHub Actions Deploy Contract

This host does not expose public SSH. A GitHub-hosted runner must join Tailscale first, then SSH to `gha-ssh`.

Required GitHub secrets:

- `TS_OAUTH_CLIENT_ID`
- `TS_OAUTH_SECRET`
- `DEPLOY_HOST`
- `DEPLOY_SSH_KEY`

Recommended repository variables or secrets:

- `DEPLOY_USER=gha-ssh`
- `TS_TAGS=tag:ci`

The example workflow is in:

- `templates/github-actions/deploy.yml.example`

The remote execution contract is:

```bash
ssh gha-ssh@$DEPLOY_HOST 'sudo -u docker /bin/bash -se --'
```

That keeps root SSH disabled and limits CI to running commands as the `docker` user through the sudoers bridge.

## Validation Checklist

Host:

- `systemctl is-enabled tailscaled nftables fail2ban ssh`
- `systemctl is-active tailscaled nftables fail2ban ssh`
- `systemctl is-enabled update-cloudflare-nft-sets.timer`
- `tailscale status`
- `nft list ruleset`
- `fail2ban-client status sshd`

Rootless Docker:

- `sudo -u docker env XDG_RUNTIME_DIR=/run/user/$(id -u docker) systemctl --user status docker.service`
- `sudo -u docker env XDG_RUNTIME_DIR=/run/user/$(id -u docker) DOCKER_HOST=unix:///run/user/$(id -u docker)/docker.sock docker ps`

Stack:

- `systemctl status supabase-direct-proxy.service`
- `sudo -u docker env XDG_RUNTIME_DIR=/run/user/$(id -u docker) DOCKER_HOST=unix:///run/user/$(id -u docker)/docker.sock docker compose --env-file /home/docker/deploy/images.env -f /home/docker/deploy/compose.yaml ps`
- `sudo -u docker env XDG_RUNTIME_DIR=/run/user/$(id -u docker) DOCKER_HOST=unix:///run/user/$(id -u docker)/docker.sock docker run --rm alpine:3.20 sh -lc 'apk add --no-cache postgresql-client busybox-extras >/dev/null && nc -vz 10.0.2.2 6543 && PGCONNECT_TIMEOUT=8 pg_isready -h 10.0.2.2 -p 6543 -d postgres'`
- `curl -I https://$APP_DOMAIN`
- `curl -I https://$API_DOMAIN`

## Notes

- The firewall trusts Cloudflare source IPs for `80/443` and Tailscale only for SSH.
- The Cloudflare refresh timer updates both nftables and the Caddy trusted proxy list.
- Rootless containers can reach host loopback through `10.0.2.2` because the docker user service sets `DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false`.
- If the API must use the Supabase direct IPv6 endpoint, run the host-local proxy on `127.0.0.1:6543` and point the API at `10.0.2.2:6543`.
- The current live deploy model uses the `gha-ssh` sudo bridge. If you later want a stricter forced-command SSH gateway, use the staged pattern from `/etc/ssh/sshd_config.stage.d` as a separate hardening step rather than baking it into this baseline.
- Official references used while shaping the proxy and CI templates:
  - Caddy trusted proxies: https://caddyserver.com/docs/caddyfile/options
  - Caddy reverse proxy: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
  - Tailscale GitHub Action: https://tailscale.com/docs/integrations/github/github-action
