#!/usr/bin/env bash
set -euo pipefail

# Installation script for MacOS and Ubuntu
# - Detects the OS and installs the correct dependencies
# - Installs the correct version of Ruby and Node
# - Installs and sets up bundler and corepack
# - Installs other system dependencies via the package manager
# - long-running steps are checked, and skipped if already installed
#
# Usage: ./install_deps.sh [--macos|--ubuntu]
# If no argument is provided, OS will be auto-detected


# Helper functions
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Colors for output
green="\033[0;32m"
red="\033[0;31m"
yellow="\033[0;33m"
reset="\033[0m"

header() { echo -e "${green}==> $1${reset}"; }
info() { echo -e "${yellow}==>    $1${reset}"; }
error() { echo -e "${red}==> $1${reset}"; }

# Parse command line arguments
parse_args() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  case "$1" in
    --macos)
      echo "macos"
      ;;
    --ubuntu)
      echo "ubuntu"
      ;;
    *)
      error "Unknown argument: $1"
      error "Usage: $0 [--macos|--ubuntu]"
      exit 1
      ;;
  esac
}

# Detect OS
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
      echo "ubuntu"
    else
      error "Unsupported OS: $ID"
      exit 1
    fi
  else
    error "Could not detect OS"
    exit 1
  fi
}

# Determine OS - either from command line or auto-detection
MANUAL_OS=$(parse_args "$@")
if [[ -n "$MANUAL_OS" ]]; then
  OS="$MANUAL_OS"
  info "Using manually specified OS: $OS"
else
  OS=$(detect_os)
  info "Detected OS: $OS"
fi

# INSTALL RUBY
# We'll use rbenv (with the ruby-build plugin) to install
# the version of ruby specified in .ruby-version
# https://github.com/rbenv/rbenv
# https://github.com/rbenv/ruby-build
header "Install Ruby..."

if [[ "$OS" == "macos" ]]; then
  brew install ruby ruby-build
elif [[ "$OS" == "ubuntu" ]]; then
  sudo apt update
  sudo apt install -y \
    rbenv ruby-build git \
    build-essential autoconf bison libssl-dev zlib1g-dev \
    libreadline-dev libyaml-dev libffi-dev libgmp-dev
fi

RUBY_VERSION=$(cat .ruby-version)
if ! rbenv versions --bare | grep -qx "$RUBY_VERSION"; then
  info "Installing Ruby $RUBY_VERSION... - THIS MAY TAKE A WHILE!"
  rbenv install --verbose "$RUBY_VERSION"
else
  info "Ruby $RUBY_VERSION already installed."
fi
rbenv local "$RUBY_VERSION"

# INSTALL NODE
# We're using the official install script from nvm-sh/nvm
# See: https://github.com/nvm-sh/nvm?tab=readme-ov-file#install--update-script
header "Install Node..."
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  info "Installing nvm..."
  if [[ "$OS" == "macos" ]]; then
    brew install curl
  elif [[ "$OS" == "ubuntu" ]]; then
    sudo apt install -y curl
  fi
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
else
  info "nvm already installed."
fi

NODE_VERSION=$(cat .node-version)
export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if ! nvm ls "$NODE_VERSION" | grep -q "$NODE_VERSION"; then
  info "Installing Node $NODE_VERSION..."
  nvm install "$NODE_VERSION"
else
  info "Node $NODE_VERSION already installed."
fi
nvm use "$NODE_VERSION"

# INSTALL BUNDLER & COREPACK
header "Setting up Ruby bundler gem..."
if ! command_exists bundle; then
  gem install bundler
fi
bundle config --local without production staging
if ! command_exists dotenv; then
  gem install dotenv # NOTE: should we just add this to the gemfile?
fi

header "Setting up corepack..."
corepack enable

# INSTALL DB DEPS
header "Installing DB packages..."
if [[ "$OS" == "macos" ]]; then
  brew install mysql@8.0 percona-toolkit
  brew link --force mysql@8.0
  brew install openssl
  bundle config --global build.mysql2 --with-opt-dir="$(brew --prefix openssl)"
  brew services stop mysql@8.0
elif [[ "$OS" == "ubuntu" ]]; then
  sudo apt install -y libmysqlclient-dev percona-toolkit mysql-client libxslt-dev libxml2-dev
fi

# INSTALL IMAGE PROCESSING LIBRARIES
header "Installing image processing libraries..."
if [[ "$OS" == "macos" ]]; then
  brew install imagemagick libvips ffmpeg
elif [[ "$OS" == "ubuntu" ]]; then
  sudo apt install -y imagemagick libvips-dev ffmpeg pdftk
fi

# INSTALL CERT UTILS
header "Installing cert utils..."
if [[ "$OS" == "macos" ]]; then
  brew install mkcert
elif [[ "$OS" == "ubuntu" ]]; then
  sudo apt install -y mkcert libnss3-tools
fi

header "Setup complete!"
