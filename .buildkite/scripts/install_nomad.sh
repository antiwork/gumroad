#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") install_nomad.sh: $1${NC}"
}

install_nomad() {
  NOMAD_VERSION="0.8.3"

  if ! command -v nomad &> /dev/null; then
    logger "Installing Nomad ${NOMAD_VERSION}"
    wget -qO /tmp/nomad.zip "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
    sudo unzip -o /tmp/nomad.zip -d /usr/local/bin/
    rm /tmp/nomad.zip
    sudo chmod +x /usr/local/bin/nomad
    nomad --version
  else
    logger "Nomad already installed. Version: $(nomad --version)"
  fi
}
