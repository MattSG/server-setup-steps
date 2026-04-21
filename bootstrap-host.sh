#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

DOCKER_USER="${DOCKER_USER:-docker}"
DOCKER_UID="${DOCKER_UID:-1000}"
DOCKER_SUBID_START="${DOCKER_SUBID_START:-100000}"
DOCKER_SUBID_COUNT="${DOCKER_SUBID_COUNT:-65536}"

DEPLOY_USER="${DEPLOY_USER:-gha-ssh}"
DEPLOY_UID="${DEPLOY_UID:-1001}"
DEPLOY_SUBID_START="${DEPLOY_SUBID_START:-165536}"
DEPLOY_SUBID_COUNT="${DEPLOY_SUBID_COUNT:-65536}"

TAILSCALE_TRACK="${TAILSCALE_TRACK:-stable}"
TAILSCALE_CODENAME="${TAILSCALE_CODENAME:-trixie}"

APT_PACKAGES=(
  acl
  apparmor
  apparmor-utils
  auditd
  ca-certificates
  curl
  docker.io
  docker-cli
  docker-compose
  fail2ban
  fuse-overlayfs
  gnupg
  jq
  needrestart
  nftables
  ripgrep
  rootlesskit
  slirp4netns
  socat
  tailscale
  uidmap
)

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

install_template() {
  local src="$1"
  local dst="$2"
  local mode="$3"
  install -D -m "${mode}" "${src}" "${dst}"
}

ensure_group() {
  local name="$1"
  if ! getent group "${name}" >/dev/null; then
    groupadd "${name}"
  fi
}

ensure_user() {
  local name="$1"
  local uid="$2"

  if id -u "${name}" >/dev/null 2>&1; then
    return
  fi

  useradd --create-home --shell /bin/bash --uid "${uid}" "${name}"
}

ensure_subid() {
  local file="$1"
  local user="$2"
  local start="$3"
  local count="$4"

  if grep -qE "^${user}:" "${file}" 2>/dev/null; then
    return
  fi

  printf '%s:%s:%s\n' "${user}" "${start}" "${count}" >>"${file}"
}

write_tailscale_repo() {
  curl -fsSL "https://pkgs.tailscale.com/${TAILSCALE_TRACK}/debian/${TAILSCALE_CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg

  cat >/etc/apt/sources.list.d/tailscale.list <<EOF
# Tailscale packages for debian ${TAILSCALE_CODENAME}
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/${TAILSCALE_TRACK}/debian ${TAILSCALE_CODENAME} main
EOF
}

setup_users() {
  ensure_user "${DOCKER_USER}" "${DOCKER_UID}"
  ensure_user "${DEPLOY_USER}" "${DEPLOY_UID}"

  ensure_subid /etc/subuid "${DOCKER_USER}" "${DOCKER_SUBID_START}" "${DOCKER_SUBID_COUNT}"
  ensure_subid /etc/subgid "${DOCKER_USER}" "${DOCKER_SUBID_START}" "${DOCKER_SUBID_COUNT}"
  ensure_subid /etc/subuid "${DEPLOY_USER}" "${DEPLOY_SUBID_START}" "${DEPLOY_SUBID_COUNT}"
  ensure_subid /etc/subgid "${DEPLOY_USER}" "${DEPLOY_SUBID_START}" "${DEPLOY_SUBID_COUNT}"

  install -d -m 0700 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/.ssh"
  install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
  install -d -m 0755 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/deploy/caddy"
  install -d -m 0755 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/deploy/state"
  install -d -m 0755 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/.config/systemd/user"
}

install_host_templates() {
  install -d -m 0755 /etc/nftables.d
  install -d -m 0755 /etc/systemd/journald.conf.d
  install -d -m 0755 /etc/ssh/sshd_config.d
  install -d -m 0755 /etc/fail2ban/jail.d
  install -d -m 0755 /usr/local/sbin
  install -d -m 0755 /etc/systemd/system
  install -d -m 0755 /etc/sudoers.d

  install_template "${TEMPLATES_DIR}/sysctl/60-vm-hardening.conf" /etc/sysctl.d/60-vm-hardening.conf 0644
  install_template "${TEMPLATES_DIR}/journald/60-persistent.conf" /etc/systemd/journald.conf.d/60-persistent.conf 0644
  install_template "${TEMPLATES_DIR}/sshd/90-hardening.conf" /etc/ssh/sshd_config.d/90-hardening.conf 0644
  install_template "${TEMPLATES_DIR}/sshd/95-gha-ssh.conf" /etc/ssh/sshd_config.d/95-gha-ssh.conf 0644
  install_template "${TEMPLATES_DIR}/fail2ban/sshd.local" /etc/fail2ban/jail.d/sshd.local 0644
  install_template "${TEMPLATES_DIR}/nftables.conf" /etc/nftables.conf 0644
  install_template "${TEMPLATES_DIR}/update-cloudflare-nft-sets" /usr/local/sbin/update-cloudflare-nft-sets 0755
  install_template "${TEMPLATES_DIR}/update-cloudflare-nft-sets.service" /etc/systemd/system/update-cloudflare-nft-sets.service 0644
  install_template "${TEMPLATES_DIR}/update-cloudflare-nft-sets.timer" /etc/systemd/system/update-cloudflare-nft-sets.timer 0644
  install_template "${TEMPLATES_DIR}/systemd/supabase-direct-proxy.service" /etc/systemd/system/supabase-direct-proxy.service 0644
  [[ -f /etc/default/supabase-direct-proxy ]] || install_template "${TEMPLATES_DIR}/systemd/supabase-direct-proxy.env.example" /etc/default/supabase-direct-proxy 0600
  install_template "${TEMPLATES_DIR}/sudoers/gha-ssh-docker-bridge" /etc/sudoers.d/gha-ssh-docker-bridge 0440

  install_template "${TEMPLATES_DIR}/docker-user/docker.service" "/home/${DOCKER_USER}/.config/systemd/user/docker.service" 0644
  install_template "${TEMPLATES_DIR}/systemd/supabase-direct-proxy" /usr/local/bin/supabase-direct-proxy 0755
  chown "${DOCKER_USER}:${DOCKER_USER}" "/home/${DOCKER_USER}/.config/systemd/user/docker.service"
}

install_packages() {
  write_tailscale_repo
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
}

configure_services() {
  /usr/sbin/sshd -t
  /usr/local/sbin/update-cloudflare-nft-sets
  sysctl --system >/dev/null

  systemctl daemon-reload
  systemctl disable --now docker.service docker.socket containerd.service >/dev/null 2>&1 || true
  systemctl enable --now tailscaled nftables fail2ban ssh update-cloudflare-nft-sets.timer
  systemctl restart systemd-journald
}

enable_rootless_docker() {
  local uid runtime_dir
  uid="$(id -u "${DOCKER_USER}")"
  runtime_dir="/run/user/${uid}"

  loginctl enable-linger "${DOCKER_USER}"
  systemctl start "user@${uid}.service"

  runuser -u "${DOCKER_USER}" -- env XDG_RUNTIME_DIR="${runtime_dir}" systemctl --user daemon-reload
  runuser -u "${DOCKER_USER}" -- env XDG_RUNTIME_DIR="${runtime_dir}" systemctl --user enable --now docker.service
}

print_next_steps() {
  cat <<EOF

Host bootstrap complete.

Next:
  1. Join Tailscale: tailscale up --ssh
  2. Add the GitHub Actions public key to /home/${DEPLOY_USER}/.ssh/authorized_keys
  3. Fill /etc/default/supabase-direct-proxy with the real Supabase direct host
  4. Enable the proxy: systemctl enable --now supabase-direct-proxy.service
  5. Run ${SCRIPT_DIR}/configure-stack.sh
  6. Fill /home/${DOCKER_USER}/deploy/*.env with real values
  7. Start the stack: ${SCRIPT_DIR}/configure-stack.sh --start --pull
EOF
}

main() {
  require_root
  log "Installing packages and Tailscale apt source"
  install_packages

  log "Creating users and deployment directories"
  setup_users

  log "Installing host templates"
  install_host_templates

  log "Applying host services and firewall"
  configure_services

  log "Enabling rootless Docker for ${DOCKER_USER}"
  enable_rootless_docker

  print_next_steps
}

main "$@"
