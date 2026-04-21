#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

DOCKER_USER="${DOCKER_USER:-docker}"
DOCKER_UID="${DOCKER_UID:-1000}"

DEPLOY_USER="${DEPLOY_USER:-gha-ssh}"
DEPLOY_UID="${DEPLOY_UID:-1001}"

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
  gnupg
  jq
  needrestart
  nftables
  ripgrep
  tailscale
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

write_tailscale_repo() {
  curl -fsSL "https://pkgs.tailscale.com/${TAILSCALE_TRACK}/debian/${TAILSCALE_CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg

  cat >/etc/apt/sources.list.d/tailscale.list <<EOF
# Tailscale packages for debian ${TAILSCALE_CODENAME}
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/${TAILSCALE_TRACK}/debian ${TAILSCALE_CODENAME} main
EOF
}

setup_users() {
  ensure_group docker
  ensure_user "${DOCKER_USER}" "${DOCKER_UID}"
  ensure_user "${DEPLOY_USER}" "${DEPLOY_UID}"
  usermod -aG docker "${DOCKER_USER}"

  install -d -m 0700 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/.ssh"
  install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
  install -d -m 0755 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/deploy/caddy"
  install -d -m 0755 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "/home/${DOCKER_USER}/deploy/state"
}

install_host_templates() {
  install -d -m 0755 /etc/docker
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
  install_template "${TEMPLATES_DIR}/docker/daemon.json" /etc/docker/daemon.json 0644
  install_template "${TEMPLATES_DIR}/nftables.conf" /etc/nftables.conf 0644
  install_template "${TEMPLATES_DIR}/update-cloudflare-nft-sets" /usr/local/sbin/update-cloudflare-nft-sets 0755
  install_template "${TEMPLATES_DIR}/update-cloudflare-nft-sets.service" /etc/systemd/system/update-cloudflare-nft-sets.service 0644
  install_template "${TEMPLATES_DIR}/update-cloudflare-nft-sets.timer" /etc/systemd/system/update-cloudflare-nft-sets.timer 0644
  install_template "${TEMPLATES_DIR}/sudoers/gha-ssh-docker-bridge" /etc/sudoers.d/gha-ssh-docker-bridge 0440
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
  systemctl enable --now tailscaled nftables fail2ban ssh update-cloudflare-nft-sets.timer
  systemctl enable --now containerd.service docker.service docker.socket
  systemctl restart systemd-journald
}

print_next_steps() {
  cat <<EOF

Host bootstrap complete.

Next:
  1. Join Tailscale: tailscale up --ssh
  2. Add the GitHub Actions public key to /home/${DEPLOY_USER}/.ssh/authorized_keys
  3. Run ${SCRIPT_DIR}/configure-stack.sh
  4. Fill /home/${DOCKER_USER}/deploy/*.env with real values
  5. Start the stack: ${SCRIPT_DIR}/configure-stack.sh --start --pull
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

  print_next_steps
}

main "$@"
