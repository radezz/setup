#!/usr/bin/env bash
# dev-minimal-bootstrap.sh
# Installs: nvm, Node LTS (via nvm), Claude Code CLI, kind, kubectl, creates a Python venv in the home directory,
# installs the Python uv package manager via pip inside the venv, and generates an SSH key for GitHub.
# Tested on: Ubuntu/Debian (apt), Fedora/RHEL/CentOS (dnf/yum), Arch/Manjaro (pacman), Alpine (apk)
# Usage:
#   curl -fsSLO https://example.com/dev-minimal-bootstrap.sh && chmod +x dev-minimal-bootstrap.sh
#   sudo ./dev-minimal-bootstrap.sh

set -euo pipefail

# --- helpers ---
if [[ -t 1 ]]; then CBLUE='\033[34m'; CGREEN='\033[32m'; CYELLOW='\033[33m'; CRED='\033[31m'; C0='\033[0m'; else CBLUE=""; CGREEN=""; CYELLOW=""; CRED=""; C0=""; fi
say(){ echo -e "${CBLUE}[+]${C0} $*"; }
ok(){ echo -e "${CGREEN}[ok]${C0} $*"; }
warn(){ echo -e "${CYELLOW}[!]${C0} $*"; }
fail(){ echo -e "${CRED}[x]${C0} $*" >&2; exit 1; }
need_root(){ [[ $(id -u) -eq 0 ]] || fail "Please run as root (use sudo)."; }
has(){ command -v "$1" >/dev/null 2>&1; }
user_invoker(){ [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] && echo "$SUDO_USER" || id -un; }

need_root
INVUSER=$(user_invoker)
HOME_OF_INVUSER=$(getent passwd "$INVUSER" | cut -d: -f6)
PYTHON_VENV_DIR="$HOME_OF_INVUSER/pyenv"

# --- customize extra package installs here ---
CUSTOM_NPM_PACKAGES=(
  # "typescript"
  # "@angular/cli"
)

CUSTOM_PIP_PACKAGES=(
  # "requests"
  # "black==23.9.1"
)

# --- detect pkg mgr ---
PM=""; if has apt-get; then PM=apt; elif has dnf; then PM=dnf; elif has yum; then PM=yum; elif has pacman; then PM=pacman; elif has apk; then PM=apk; else fail "Unsupported package manager"; fi
say "Using package manager: $PM (invoking user: $INVUSER)"

# --- base deps ---
BASE_PKGS=(curl ca-certificates tar gzip git openssh-client jq python3 python3-pip python3-venv)
case "$PM" in
  apt) apt-get update -y; apt-get install -y --no-install-recommends "${BASE_PKGS[@]}" ;;
  dnf) dnf -y upgrade --refresh || true; dnf -y install "${BASE_PKGS[@]}" ;;
  yum) yum -y update || true; yum -y install "${BASE_PKGS[@]}" ;;
  pacman) pacman -Sy --noconfirm; pacman -S --noconfirm --needed "${BASE_PKGS[@]}" ;;
  apk) apk update; apk add --no-cache "${BASE_PKGS[@]}" ;;
 esac
ok "Base packages installed"

# --- nvm + Node LTS (run as invoking user) ---
install_nvm_node(){
  say "Installing nvm and Node LTS for $INVUSER"
  su - "$INVUSER" -c "bash -lc 'export PROFILE=~/.bashrc; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'"
  su - "$INVUSER" -c "bash -lc 'export NVM_DIR=\"$HOME_OF_INVUSER/.nvm\"; [ -s \"$HOME_OF_INVUSER/.nvm/nvm.sh\" ] && . \"$HOME_OF_INVUSER/.nvm/nvm.sh\"; nvm install --lts; nvm alias default \"lts/*\"; node -v; npm -v'"
  ok "nvm + Node LTS installed"
}

# --- Claude Code CLI (npm global under nvm) ---
install_claude(){
  say "Installing Claude Code CLI (@anthropic-ai/claude-code) for $INVUSER"
  su - "$INVUSER" -c "bash -lc 'export NVM_DIR=\"$HOME_OF_INVUSER/.nvm\"; . \"$HOME_OF_INVUSER/.nvm/nvm.sh\"; npm install -g @anthropic-ai/claude-code; claude --version || claude help || true'"
  ok "Claude Code CLI installed"
}

# --- additional npm packages (optional) ---
install_custom_npm_packages(){
  if (( ${#CUSTOM_NPM_PACKAGES[@]} == 0 )); then
    say "No additional npm packages requested"
    return
  fi

  say "Installing custom npm packages for $INVUSER: ${CUSTOM_NPM_PACKAGES[*]}"
  local packages="${CUSTOM_NPM_PACKAGES[*]}"
  su - "$INVUSER" -c "bash -lc 'export NVM_DIR=\"$HOME_OF_INVUSER/.nvm\"; . \"$HOME_OF_INVUSER/.nvm/nvm.sh\"; npm install -g ${packages}'"
  ok "Custom npm packages installed"
}

# --- kind (latest) ---
install_kind(){
  say "Installing kind (latest)"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) KIND_ARCH=amd64 ;;
    aarch64|arm64) KIND_ARCH=arm64 ;;
    *) warn "Unknown arch $ARCH, trying amd64"; KIND_ARCH=amd64 ;;
  esac
  TAG=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)
  [[ -n "$TAG" && "$TAG" != "null" ]] || fail "Could not determine latest kind version"
  curl -fsSL -o /usr/local/bin/kind "https://github.com/kubernetes-sigs/kind/releases/download/${TAG}/kind-linux-${KIND_ARCH}"
  chmod +x /usr/local/bin/kind
  ok "kind $(kind --version 2>/dev/null || echo installed)"
}

# --- kubectl (latest stable) ---
install_kubectl(){
  say "Installing kubectl (stable)"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) KARCH=amd64 ;;
    aarch64|arm64) KARCH=arm64 ;;
    *) warn "Unknown arch $ARCH, trying amd64"; KARCH=amd64 ;;
  esac
  VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  [[ -n "$VER" ]] || fail "Could not get kubectl version"
  curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${VER}/bin/linux/${KARCH}/kubectl"
  curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${VER}/bin/linux/${KARCH}/kubectl.sha256"
  echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -
  chmod +x /usr/local/bin/kubectl
  ok "kubectl $(/usr/local/bin/kubectl version --client --short | tr -d '\n')"
}

# --- Python venv + uv install ---
create_python_venv_and_uv(){
  say "Creating Python virtual environment in home directory for $INVUSER"
  local VENV_DIR="$PYTHON_VENV_DIR"
  su - "$INVUSER" -c "bash -lc 'python3 -m venv $VENV_DIR'"
  su - "$INVUSER" -c "bash -lc 'source $VENV_DIR/bin/activate && python -m pip install --upgrade pip setuptools wheel uv && echo \"Virtual environment activated and uv installed: $VENV_DIR\"'"
  ok "Python virtual environment created and uv installed at $VENV_DIR"
  source "$VENV_DIR/bin/activate"
}

# --- additional pip packages inside venv (optional) ---
install_custom_pip_packages(){
  if (( ${#CUSTOM_PIP_PACKAGES[@]} == 0 )); then
    say "No additional pip packages requested"
    return
  fi

  if [[ ! -d "$PYTHON_VENV_DIR/bin" ]]; then
    warn "Python virtual environment not found at $PYTHON_VENV_DIR; skipping custom pip packages"
    return
  fi

  say "Installing custom pip packages for $INVUSER in $PYTHON_VENV_DIR: ${CUSTOM_PIP_PACKAGES[*]}"
  local packages="${CUSTOM_PIP_PACKAGES[*]}"
  su - "$INVUSER" -c "bash -lc 'source \"$PYTHON_VENV_DIR/bin/activate\" && pip install ${packages}'"
  ok "Custom pip packages installed"
}

# --- GitHub SSH key (ed25519) ---
setup_ssh_key(){
  say "Generating GitHub SSH key (ed25519) for $INVUSER"
  su - "$INVUSER" -c "bash -lc 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'"
  KEYFILE="$HOME_OF_INVUSER/.ssh/id_ed25519"
  if [[ -f "$KEYFILE" ]]; then
    warn "Key $KEYFILE already exists; leaving it in place"
  else
    COMMENT="$INVUSER@$(hostname)"
    su - "$INVUSER" -c "ssh-keygen -t ed25519 -C '$COMMENT' -N '' -f '$KEYFILE' >/dev/null"
    ok "SSH key created: $KEYFILE"
  fi
  PUBKEY=$(su - "$INVUSER" -c "cat '$KEYFILE.pub'")
  echo
  echo "===== Add this public key to GitHub (Settings → SSH and GPG keys) ====="
  echo "$PUBKEY"
  echo "========================================================================"
}

install_nvm_node
install_claude
install_custom_npm_packages
install_kind
install_kubectl
create_python_venv_and_uv
install_custom_pip_packages
setup_ssh_key

say "All done. You may need to open a new shell for nvm, uv, and venv PATH changes to apply for user $INVUSER."
