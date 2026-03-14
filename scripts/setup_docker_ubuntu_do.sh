#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run this script as root: sudo bash $0"
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Unable to determine operating system"
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
  echo "This script only supports Ubuntu"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() {
  echo ">>> $*"
}

package_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

apt_package_has_candidate() {
  local candidate

  candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')"
  [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
}

pick_docker_repo_codename() {
  case "${VERSION_CODENAME}" in
    questing)
      # Docker's repo may lag new Ubuntu releases. noble is the closest stable fallback.
      echo "noble"
      ;;
    *)
      echo "${VERSION_CODENAME}"
      ;;
  esac
}

remove_conflicting_packages() {
  local packages_to_remove=()
  local package

  for package in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if package_installed "$package"; then
      packages_to_remove+=("$package")
    fi
  done

  if [[ ${#packages_to_remove[@]} -gt 0 ]]; then
    log "Removing conflicting packages: ${packages_to_remove[*]}"
    apt-get remove -y "${packages_to_remove[@]}"
  else
    log "No conflicting Docker packages found"
  fi
}

ensure_prerequisites() {
  log "Installing prerequisite packages"
  apt-get install -y ca-certificates curl gnupg lsb-release ufw apt-transport-https
}

ensure_docker_keyring() {
  log "Creating Docker keyring directory"
  install -m 0755 -d /etc/apt/keyrings

  local docker_keyring="/etc/apt/keyrings/docker.asc"
  local expected_fingerprint="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
  local current_fingerprint=""

  if [[ -f "${docker_keyring}" ]]; then
    current_fingerprint="$(gpg --show-keys --with-colons "${docker_keyring}" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
  fi

  if [[ "${current_fingerprint}" == "${expected_fingerprint}" ]]; then
    log "Docker GPG key already present"
  else
    log "Downloading Docker GPG key"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${docker_keyring}"
  fi

  chmod a+r "${docker_keyring}"
}

ensure_docker_repo() {
  local arch
  local codename
  local docker_list="/etc/apt/sources.list.d/docker.list"
  local docker_repo

  arch="$(dpkg --print-architecture)"
  codename="$(pick_docker_repo_codename)"

  if [[ "${codename}" != "${VERSION_CODENAME}" ]]; then
    log "Ubuntu codename ${VERSION_CODENAME} is too new for Docker's repo; using ${codename} packages"
  fi

  docker_repo="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"

  if [[ -f "${docker_list}" ]] && grep -Fxq "${docker_repo}" "${docker_list}"; then
    log "Docker apt repository already configured"
  else
    log "Configuring Docker apt repository"
    printf '%s\n' "${docker_repo}" > "${docker_list}"
  fi
}

ensure_docker_packages() {
  local packages=()
  local missing_packages=()
  local package

  if apt_package_has_candidate docker-ce && apt_package_has_candidate docker-compose-plugin; then
    packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  elif apt_package_has_candidate docker.io; then
    log "Docker CE packages are unavailable for ${VERSION_CODENAME}; falling back to Ubuntu's docker.io package"
    packages=(docker.io)

    if apt_package_has_candidate docker-compose-v2; then
      packages+=(docker-compose-v2)
    elif apt_package_has_candidate docker-compose-plugin; then
      packages+=(docker-compose-plugin)
    fi
  else
    echo "Docker packages are not available from apt. Check /etc/apt/sources.list.d/docker.list"
    echo "apt-cache policy docker-ce:"
    apt-cache policy docker-ce || true
    echo
    echo "apt-cache policy docker.io:"
    apt-cache policy docker.io || true
    exit 1
  fi

  for package in "${packages[@]}"; do
    if ! package_installed "$package"; then
      missing_packages+=("$package")
    fi
  done

  if [[ ${#missing_packages[@]} -gt 0 ]]; then
    log "Installing Docker packages: ${missing_packages[*]}"
    apt-get install -y "${packages[@]}"
  else
    log "Docker packages already installed; refreshing them to keep plugin/systemd units aligned"
    apt-get install -y --reinstall "${packages[@]}"
  fi
}

ensure_docker_socket_and_service() {
  log "Reloading systemd units"
  systemctl daemon-reload

  log "Enabling Docker socket and service"
  systemctl enable docker.socket docker >/dev/null

  if ! systemctl is-active --quiet docker.socket; then
    log "Starting Docker socket"
    systemctl start docker.socket
  else
    log "Docker socket already running"
  fi

  if systemctl is-active --quiet docker; then
    log "Restarting Docker service"
    systemctl restart docker
  else
    log "Starting Docker service"
    systemctl start docker
  fi
}

ensure_docker_group_membership() {
  local target_user="${SUDO_USER:-root}"

  if [[ "${target_user}" == "root" ]]; then
    log "Skipping docker group update for root user"
    return
  fi

  if ! getent group docker >/dev/null 2>&1; then
    log "Creating docker group"
    groupadd docker
  fi

  if id -nG "${target_user}" | tr ' ' '\n' | grep -qx docker; then
    log "User ${target_user} is already in the docker group"
  else
    log "Adding ${target_user} to the docker group"
    usermod -aG docker "${target_user}"
  fi
}

ensure_ufw_ssh() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi

  if ufw status | grep -q "Status: active"; then
    log "UFW is active; ensuring OpenSSH is allowed"
    ufw allow OpenSSH >/dev/null 2>&1 || true
  else
    log "UFW is installed but not active; skipping firewall changes"
  fi
}

verify_docker() {
  log "Verifying Docker daemon and Compose"

  if ! systemctl is-active --quiet docker.socket; then
    echo "docker.socket is not active"
    systemctl status docker.socket --no-pager -l || true
    exit 1
  fi

  if ! systemctl is-active --quiet docker; then
    echo "docker.service failed to start"
    systemctl status docker.service --no-pager -l || true
    journalctl -u docker.service -n 100 --no-pager || true
    exit 1
  fi

  docker version

  if docker compose version >/dev/null 2>&1; then
    docker compose version
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose version
  else
    log "Docker Compose plugin is not installed; continuing with Docker Engine only"
  fi
}

log "Updating apt package index"
apt-get update

remove_conflicting_packages
ensure_prerequisites
ensure_docker_keyring
ensure_docker_repo

log "Updating apt package index after Docker repository setup"
apt-get update

ensure_docker_packages
ensure_docker_socket_and_service
ensure_docker_group_membership
ensure_ufw_ssh
verify_docker

echo
echo "Docker is installed and running."
echo "If you were added to the docker group, log out and back in before running docker without sudo."
