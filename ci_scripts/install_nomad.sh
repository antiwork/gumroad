#!/bin/bash

set -e

NOMAD_VERSION=${NOMAD_VERSION:-"0.8.3"}

GREEN='\033[0;32m'
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT install_aws_cli.sh: $1${NC}"
}

function install_nomad() {
  logger "install nomad"
  wget -qO /tmp/nomad.zip "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"

  sudo unzip -o /tmp/nomad.zip -d /usr/local/bin/
  rm /tmp/nomad.zip

  sudo chmod +x /usr/local/bin/nomad
  nomad --version
}
