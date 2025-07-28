
#!/usr/bin/env bash
set -eo pipefail

# Installation script for MacOS and Ubuntu system dependencies,
# via the corresponding package managers.
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

# Select OS: from CL argument, or auto-detection
MANUAL_OS=$(parse_args "$@")
if [[ -n "$MANUAL_OS" ]]; then
  OS="$MANUAL_OS"
  header "Using manually specified OS: $OS"
else
  OS=$(detect_os)
  header "Detected OS: $OS"
fi

# INSTALL IMAGE PROCESSING LIBRARIES
# We use imagemagick for preview editing.
# For newer image formats we use libvips for image processing with ActiveStorage.
# We use ffprobe that comes with FFmpeg package to fetch metadata from video files.
# We use pdftk to stamp PDF files with the Gumroad logo and the buyers' emails.
# Note: on MacOS pdftk needs to be installed manually, see README file.
header "Installing image processing libraries..."
if [[ "$OS" == "macos" ]]; then
  brew install imagemagick libvips ffmpeg # No pdftk
elif [[ "$OS" == "ubuntu" ]]; then
  sudo apt install -y imagemagick libvips-dev ffmpeg pdftk
fi


header "Setup complete!"
