#!/bin/bash
# =============================================================================
# bootstrap-linux.sh — Set up dotfiles on a Rocky Linux server
# Run as your user (not root), it will sudo when needed
# =============================================================================
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}==>${NC} $1"; }
fatal() { echo -e "${RED}==>${NC} $1" >&2; exit 1; }

# -------------------------------------------------------------------------
# Verify SSH agent forwarding works (needed to clone the private dotfiles
# repo via SSH). Fail early before we spend 5 minutes on dnf installs.
# -------------------------------------------------------------------------
if ! ssh-add -l >/dev/null 2>&1; then
  fatal "No keys in SSH agent. Reconnect with agent forwarding:
    ssh -A ${USER}@$(hostname)
  or add 'ForwardAgent yes' for this host in your local ~/.ssh/config.
  This bootstrap clones a private GitHub repo via SSH and needs your
  forwarded key."
fi
info "SSH agent has $(ssh-add -l | wc -l) key(s) available — good."

# -------------------------------------------------------------------------
# Install system packages
# -------------------------------------------------------------------------
info "Installing system packages..."
sudo dnf install -y epel-release
sudo dnf install -y \
  zsh \
  tmux \
  git \
  git-delta \
  bat \
  fd-find \
  fzf \
  util-linux-user \
  curl \
  unzip \
  tar \
  nodejs \
  npm \
  python3-pip

# fd is called fd-find on some systems — symlink if needed
if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
  sudo ln -sf "$(which fdfind)" /usr/local/bin/fd
fi

# -------------------------------------------------------------------------
# Python — Mason-installed black needs python3 >= 3.10
# If the default python3 is older, install the newest dnf-available
# python3.X and let Mason discover it on PATH.
# -------------------------------------------------------------------------
need_newer_python=true
if command -v python3 &>/dev/null; then
  pyver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  pymajor=${pyver%.*}
  pyminor=${pyver#*.}
  if [ "$pymajor" -ge 3 ] && [ "$pyminor" -ge 10 ]; then
    need_newer_python=false
    info "python3 $pyver already meets Mason's >= 3.10 requirement"
  fi
fi

if $need_newer_python; then
  info "Default python3 < 3.10 — installing a newer python3.X for Mason..."
  installed_alt_python=false
  for v in 3.13 3.12 3.11 3.10; do
    if sudo dnf install -y "python$v" 2>/dev/null; then
      info "Installed python$v"
      installed_alt_python=true
      break
    fi
  done
  if ! $installed_alt_python; then
    warn "No python3.10+ available via dnf — Mason black install will fail."
    warn "Install Python 3.10+ manually (e.g. pyenv) or replace black with ruff."
  fi
fi

# -------------------------------------------------------------------------
# Neovim — Rocky's nvim is 0.8, modern plugins need 0.11+
# Install the official AppImage, extracted (no FUSE required)
# -------------------------------------------------------------------------
required_nvim="0.11.0"
need_nvim_install=true
if command -v nvim &>/dev/null; then
  current=$(nvim --version | head -1 | awk '{print $2}' | sed 's/^v//')
  # version >= required if min(current, required) == required (per sort -V)
  if [ "$(printf '%s\n%s\n' "$required_nvim" "$current" | sort -V | head -1)" = "$required_nvim" ]; then
    need_nvim_install=false
    info "Neovim $current already meets >= $required_nvim"
  fi
fi

if $need_nvim_install; then
  info "Installing Neovim AppImage (extracted to /opt/nvim)..."
  tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    curl -fsSL -o nvim.appimage \
      https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage
    chmod u+x nvim.appimage
    ./nvim.appimage --appimage-extract >/dev/null
    sudo rm -rf /opt/nvim
    sudo mv squashfs-root /opt/nvim
    sudo ln -sf /opt/nvim/AppRun /usr/local/bin/nvim
  )
  rm -rf "$tmpdir"
else
  info "Neovim $current already installed (>= 0.11)"
fi

# -------------------------------------------------------------------------
# Install tools not in dnf
# -------------------------------------------------------------------------

# Starship
if ! command -v starship &>/dev/null; then
  info "Installing Starship..."
  curl -sS https://starship.rs/install.sh | sh -s -- -y
fi

# zoxide
if ! command -v zoxide &>/dev/null; then
  info "Installing zoxide..."
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi

# eza
if ! command -v eza &>/dev/null; then
  info "Installing eza..."
  sudo dnf install -y eza 2>/dev/null || {
    warn "eza not in repos — installing from GitHub release..."
    EZA_VERSION=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -Lo /tmp/eza.tar.gz "https://github.com/eza-community/eza/releases/download/${EZA_VERSION}/eza_x86_64-unknown-linux-gnu.tar.gz"
    tar xzf /tmp/eza.tar.gz -C /tmp
    sudo mv /tmp/eza /usr/local/bin/
    rm -f /tmp/eza.tar.gz
  }
fi

# tree-sitter CLI (for neovim treesitter parsers)
if ! command -v tree-sitter &>/dev/null; then
  info "Installing tree-sitter CLI..."
  sudo npm install -g tree-sitter-cli 2>/dev/null || {
    warn "npm not found — treesitter parsers may need manual install in neovim"
  }
fi

# -------------------------------------------------------------------------
# Install chezmoi and apply dotfiles (clone via SSH using forwarded agent)
# -------------------------------------------------------------------------

# Trust GitHub's SSH host key non-interactively (idempotent)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if ! ssh-keygen -F github.com -f ~/.ssh/known_hosts >/dev/null 2>&1; then
  info "Adding GitHub to ~/.ssh/known_hosts..."
  ssh-keyscan -t ed25519,ecdsa,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null
  chmod 644 ~/.ssh/known_hosts
fi

# Confirm the forwarded agent is actually authorized on GitHub
info "Verifying GitHub SSH access via forwarded agent..."
if ssh -T -o BatchMode=yes git@github.com 2>&1 | grep -q "successfully authenticated"; then
  info "GitHub auth OK"
else
  fatal "Forwarded SSH key is not authorized on GitHub. Add the public key
  to https://github.com/settings/keys and reconnect with 'ssh -A'."
fi

info "Installing chezmoi and applying dotfiles..."
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply --ssh seamusharris

# -------------------------------------------------------------------------
# Set zsh as default shell
# -------------------------------------------------------------------------
ZSH_PATH=$(which zsh)
if [ "$SHELL" != "$ZSH_PATH" ]; then
  info "Setting zsh as default shell..."
  # Ensure zsh is in /etc/shells
  grep -q "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells
  chsh -s "$ZSH_PATH"
fi

# -------------------------------------------------------------------------
# First run info
# -------------------------------------------------------------------------
info "Done!"
echo ""
echo "  Log out and back in (or run: exec zsh)"
echo "  Zinit will auto-install plugins on first shell launch (~10s)"
echo "  Run 'nvim' to auto-install neovim plugins (Mason will fetch LSP servers)"
echo ""
echo "  Key bindings:"
echo "    Ctrl+R        fuzzy history search"
echo "    Ctrl+Space    accept autosuggestion"
echo "    Tab           fzf-powered completion"
echo "    z <dir>       smart cd (zoxide)"
echo "    vi / vim      opens neovim"
echo ""
