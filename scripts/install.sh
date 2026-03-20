#!/usr/bin/env bash
# install.sh — host installer for gruv (no gruv container)
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Hyper-Unearthing/rubister/gruv-base-2/scripts/install.sh)
# or:
#   bash scripts/install.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Hyper-Unearthing/rubister.git}"
REPO_BRANCH="${REPO_BRANCH:-gruv-base-2}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/gruv}"
RBENV_DIR="${RBENV_DIR:-${HOME}/.rbenv}"

FORGEJO_CONTAINER_NAME="${FORGEJO_CONTAINER_NAME:-forgejo}"
FORGEJO_IMAGE="${FORGEJO_IMAGE:-codeberg.org/forgejo/forgejo:10}"
FORGEJO_HTTP_PORT="${FORGEJO_HTTP_PORT:-3000}"
FORGEJO_SSH_PORT="${FORGEJO_SSH_PORT:-2222}"
FORGEJO_DATA_DIR="${FORGEJO_DATA_DIR:-${HOME}/forgejo}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${CYAN}>>>${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET}  $*"; }
warn() { echo -e "${YELLOW}!${RESET}   $*"; }
die()  { echo -e "${RED}✗${RESET}  $*" >&2; exit 1; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "'$1' is required but not found in PATH. $2"
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local required="${3:-false}"

  # Read from /dev/tty so this works when stdin is a pipe (e.g. bash <(curl ...))
  while true; do
    if [[ -n "${default}" ]]; then
      printf '%s [%s]: ' "${prompt}" "${default}" >/dev/tty
    else
      printf '%s: ' "${prompt}" >/dev/tty
    fi

    read -r value </dev/tty
    value="${value:-$default}"

    if [[ "${required}" == "true" && -z "${value}" ]]; then
      echo "  This value is required." >/dev/tty
      continue
    fi

    echo "${value}"
    return
  done
}

ask_yn() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix="[y/N]"

  [[ "${default}" == "y" ]] && suffix="[Y/n]"

  # Read from /dev/tty so this works when stdin is a pipe (e.g. bash <(curl ...))
  printf '%s %s: ' "${prompt}" "${suffix}" >/dev/tty
  read -r input </dev/tty
  input="${input,,}"

  if [[ -z "${input}" ]]; then
    [[ "${default}" == "y" ]] && return 0 || return 1
  fi

  [[ "${input}" == "y" || "${input}" == "yes" ]]
}

install_apt_dependencies() {
  local apt_pkgs=(
    build-essential
    libssl-dev
    libreadline-dev
    zlib1g-dev
    libffi-dev
    libyaml-dev
    libgdbm-dev
    libncurses5-dev
    libgmp-dev
    curl
    git
  )

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing build dependencies with apt..."
    if [[ "${EUID}" -ne 0 ]]; then
      sudo apt-get update -qq
      sudo apt-get install -y "${apt_pkgs[@]}"
    else
      apt-get update -qq
      apt-get install -y "${apt_pkgs[@]}"
    fi
    ok "Build dependencies installed."
  else
    warn "apt-get not found. Skipping automatic package installation."
  fi
}

setup_rbenv_and_ruby() {
  local ruby_version
  ruby_version="$(cat .ruby-version)"

  log "Setting up rbenv..."

  if [[ ! -d "${RBENV_DIR}" ]]; then
    git clone https://github.com/rbenv/rbenv.git "${RBENV_DIR}"
    ok "rbenv installed."
  else
    git -C "${RBENV_DIR}" pull --ff-only
    ok "rbenv updated."
  fi

  export PATH="${RBENV_DIR}/bin:${RBENV_DIR}/shims:${PATH}"
  eval "$(rbenv init - bash)"

  local ruby_build_dir="${RBENV_DIR}/plugins/ruby-build"
  if [[ ! -d "${ruby_build_dir}" ]]; then
    git clone https://github.com/rbenv/ruby-build.git "${ruby_build_dir}"
    ok "ruby-build installed."
  else
    git -C "${ruby_build_dir}" pull --ff-only
    ok "ruby-build updated."
  fi

  if rbenv versions --bare | grep -qx "${ruby_version}"; then
    ok "Ruby ${ruby_version} already installed."
  else
    log "Installing Ruby ${ruby_version}..."
    rbenv install "${ruby_version}"
    ok "Ruby ${ruby_version} installed."
  fi

  rbenv global "${ruby_version}"
  rbenv rehash

  if ! gem list bundler -i >/dev/null 2>&1; then
    log "Installing Bundler..."
    gem install bundler --no-document
    rbenv rehash
  fi

  ok "Ruby toolchain ready."
}

add_rbenv_to_profile() {
  local profile
  if [[ -n "${ZSH_VERSION:-}" || "${SHELL}" == */zsh ]]; then
    profile="${HOME}/.zshrc"
  elif [[ -f "${HOME}/.bashrc" ]]; then
    profile="${HOME}/.bashrc"
  else
    profile="${HOME}/.bash_profile"
  fi

  if [[ -f "${profile}" ]] && grep -q 'rbenv init' "${profile}"; then
    return
  fi

  {
    echo
    echo '# rbenv'
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
    echo 'eval "$(rbenv init - bash)"'
  } >> "${profile}"

  warn "Added rbenv init to ${profile} — open a new shell or run: source ${profile}"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker found."
    return
  fi

  log "Docker not found — installing via setup_docker_ubuntu_do.sh..."

  if ! command -v apt-get >/dev/null 2>&1; then
    die "Docker is required but not installed, and automatic installation requires apt-get (Ubuntu/Debian). Install Docker manually: https://docs.docker.com/engine/install/"
  fi

  local setup_script="${INSTALL_DIR}/scripts/setup_docker_ubuntu_do.sh"
  if [[ ! -f "${setup_script}" ]]; then
    die "Docker setup script not found at ${setup_script}"
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    sudo bash "${setup_script}"
  else
    bash "${setup_script}"
  fi

  ok "Docker installed."
}

# Run docker, falling back to sudo when the current session doesn't yet have
# docker group membership (e.g. immediately after a fresh install where the
# group change only takes effect after re-login).
docker_cmd() {
  if [[ "${EUID}" -eq 0 ]] || groups 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

forgejo_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local token="${4:-}"
  local basic_user="${5:-}"
  local basic_pass="${6:-}"

  local url="http://localhost:${FORGEJO_HTTP_PORT}/api/v1${path}"
  local curl_args=(-s -X "${method}" -H 'Content-Type: application/json' -H 'Accept: application/json')

  [[ -n "${token}" ]]      && curl_args+=(-H "Authorization: token ${token}")
  [[ -n "${basic_user}" ]] && curl_args+=(-u "${basic_user}:${basic_pass}")
  [[ -n "${body}" ]]       && curl_args+=(-d "${body}")

  curl "${curl_args[@]}" "${url}"
}

setup_forgejo() {
  ensure_docker

  # Forgejo refuses to run as uid 0. When the installer runs as root (common on
  # cloud VMs), fall back to 1000:1000 so the in-container git user is non-root.
  local forgejo_uid forgejo_gid
  forgejo_uid="$(id -u)"; [[ "${forgejo_uid}" == "0" ]] && forgejo_uid=1000
  forgejo_gid="$(id -g)"; [[ "${forgejo_gid}" == "0" ]] && forgejo_gid=1000

  log "Preparing Forgejo data directory at ${FORGEJO_DATA_DIR}..."
  mkdir -p "${FORGEJO_DATA_DIR}"
  chown -R "${forgejo_uid}:${forgejo_gid}" "${FORGEJO_DATA_DIR}" 2>/dev/null || true

  log "Pulling Forgejo image (${FORGEJO_IMAGE})..."
  docker_cmd pull "${FORGEJO_IMAGE}"

  if docker_cmd ps -a --format '{{.Names}}' | grep -qx "${FORGEJO_CONTAINER_NAME}"; then
    log "Forgejo container already exists — removing to recreate..."
    docker_cmd rm -f "${FORGEJO_CONTAINER_NAME}" >/dev/null
  fi

  local forgejo_owner forgejo_password
  forgejo_owner="$(ask 'Forgejo admin username' 'admin' true)"
  forgejo_password="$(ask 'Forgejo admin password' '' true)"

  log "Starting Forgejo (headless, no web setup wizard)..."
  docker_cmd run -d \
    --name "${FORGEJO_CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${FORGEJO_HTTP_PORT}:3000" \
    -p "${FORGEJO_SSH_PORT}:22" \
    -v "${FORGEJO_DATA_DIR}:/data" \
    -e USER_UID="${forgejo_uid}" \
    -e USER_GID="${forgejo_gid}" \
    -e FORGEJO__security__INSTALL_LOCK=true \
    -e FORGEJO__database__DB_TYPE=sqlite3 \
    -e "FORGEJO__server__ROOT_URL=http://localhost:${FORGEJO_HTTP_PORT}/" \
    "${FORGEJO_IMAGE}" >/dev/null

  log "Waiting for Forgejo to be ready..."
  local ready=false
  for _ in $(seq 1 40); do
    if curl -sf "http://localhost:${FORGEJO_HTTP_PORT}/api/v1/version" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
    printf '.' >/dev/tty
  done
  echo >/dev/tty

  if [[ "${ready}" != "true" ]]; then
    die "Timed out waiting for Forgejo to start."
  fi
  ok "Forgejo is up."

  log "Creating admin user '${forgejo_owner}'..."
  docker_cmd exec -u git "${FORGEJO_CONTAINER_NAME}" \
    forgejo admin user create \
    --admin \
    --username "${forgejo_owner}" \
    --password "${forgejo_password}" \
    --email "${forgejo_owner}@gruv.local" \
    --must-change-password=false
  ok "Admin user created."

  log "Creating API token..."
  local token_json
  token_json="$(forgejo_api POST "/users/${forgejo_owner}/tokens" \
    '{"name":"gruv","scopes":["write:repository","write:user","read:user"]}' \
    '' "${forgejo_owner}" "${forgejo_password}")"
  local forgejo_token
  forgejo_token="$(echo "${token_json}" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)"

  if [[ -z "${forgejo_token}" ]]; then
    die "Failed to create Forgejo API token. Response: ${token_json}"
  fi
  ok "API token created."

  git config --global --replace-all \
    "url.http://${forgejo_owner}:${forgejo_token}@localhost:${FORGEJO_HTTP_PORT}/.insteadOf" \
    "http://localhost:${FORGEJO_HTTP_PORT}/"

  ok "Configured per-host git URL rewrite for Forgejo."

  # ── Hard-fork: mirror the repo into Forgejo and repoint origin ────────────
  local forgejo_repo_name
  forgejo_repo_name="$(basename "${INSTALL_DIR}")"
  local forgejo_repo_url="http://localhost:${FORGEJO_HTTP_PORT}/${forgejo_owner}/${forgejo_repo_name}.git"

  log "Creating repository '${forgejo_repo_name}' in Forgejo..."
  local create_resp
  create_resp="$(forgejo_api POST "/user/repos" \
    "{\"name\":\"${forgejo_repo_name}\",\"private\":true,\"auto_init\":false}" \
    "${forgejo_token}")"

  # 201 = created, anything else with an "id" field is also fine (already exists)
  if echo "${create_resp}" | grep -q '"id"'; then
    ok "Forgejo repository '${forgejo_repo_name}' ready."
  else
    warn "Unexpected Forgejo repo creation response (may already exist): ${create_resp}"
  fi

  log "Pushing all branches and tags to Forgejo..."
  # The insteadOf rewrite already injects credentials, so we can use the plain URL.
  git -C "${INSTALL_DIR}" remote set-url origin "${forgejo_repo_url}" 2>/dev/null \
    || git -C "${INSTALL_DIR}" remote add origin "${forgejo_repo_url}"
  git -C "${INSTALL_DIR}" push --all  origin
  git -C "${INSTALL_DIR}" push --tags origin
  ok "Code pushed to Forgejo. origin → ${forgejo_repo_url}"
  # ──────────────────────────────────────────────────────────────────────────

  ok "Forgejo is ready at http://localhost:${FORGEJO_HTTP_PORT}"
}

echo
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         gruv host installer                  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo

require git "Install git: https://git-scm.com"

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  log "Updating existing repo in ${INSTALL_DIR} (branch: ${REPO_BRANCH})..."
  git -C "${INSTALL_DIR}" fetch origin
  git -C "${INSTALL_DIR}" checkout "${REPO_BRANCH}"
  git -C "${INSTALL_DIR}" pull --ff-only origin "${REPO_BRANCH}"
else
  log "Cloning ${REPO_URL} into ${INSTALL_DIR} (branch: ${REPO_BRANCH})..."
  git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi
ok "Repository ready."

cd "${INSTALL_DIR}"

install_apt_dependencies
setup_rbenv_and_ruby
add_rbenv_to_profile

log "Running bundle install..."
bundle install
ok "Gems installed."

gruv_name="$(ask 'What is this gruv name?' '' true)"

log "Configuring global git identity..."
git config --global user.name "${gruv_name}"
git config --global user.email "${gruv_name}@gruv.dev"
ok "git user.name/user.email configured."

setup_forgejo

echo
if ask_yn 'Run interactive gruv setup wizard now (setup.rb)?' y; then
  exec bundle exec ruby "${INSTALL_DIR}/setup.rb"
else
  echo "Setup complete. Next steps:"
  echo "  cd ${INSTALL_DIR}"
  echo "  bundle exec ruby setup.rb"
  echo "  ./gruv"
fi
