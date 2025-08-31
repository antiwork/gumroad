# Install Gumroad for development on Windows

## Table of Contents

- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Configuration](#configuration)
  - [Running Locally](#running-locally)
- [Development](#development)
  - [Logging in](#logging-in)
  - [Resetting Elasticsearch Indices](#resetting-elasticsearch-indices)
  - [Common Tasks](#common-tasks)
  - [Linting](#linting)

---

## Getting Started

### Prerequisites

#### Enable Long Paths in Git (One-time setup)

Run this in **PowerShell as Administrator** to avoid long file path issues:

```bash
git config --system core.longpaths true
```

### Install WSL and Ubuntu

1. Open **PowerShell as Administrator** and run:

   ```bash
   wsl --install
   ```

2. Restart if prompted.

3. Choose a non-root username and password in the Ubuntu setup.

4. Always launch **Ubuntu** for development work (not PowerShell or CMD).

---

## For Windows (using WSL + Ubuntu)

### Ruby

Install the version specified in `.ruby-version` (e.g., 3.4.3) using `rbenv`:

```bash
# Base toolchain + rbenv
sudo apt update
sudo apt install -y \
  rbenv ruby-build git \
  build-essential autoconf bison libssl-dev zlib1g-dev \
  libreadline-dev libyaml-dev libffi-dev libgmp-dev

# One-time shell initialisation (also add to ~/.bashrc or ~/.zshrc)
export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init -)"

# Install Ruby
rbenv install 3.4.3
rbenv global 3.4.3
```

### Node.js

Install the version specified in `.node-version` (e.g., 20.17.0) using `nvm`:

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 20.17.0
nvm use 20.17.0
```

### Docker

1. Download Docker Desktop: [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop)
2. Open Docker → ⚙️ → **Resources > WSL Integration**
3. Enable Ubuntu.
4. Ensure Docker Desktop shows **"Engine Running"**.

### MySQL & Percona Toolkit

You don’t need to run MySQL locally — only its client libraries.

```bash
sudo apt install libmysqlclient-dev mysql-client
```

> For Percona Toolkit:

```bash
sudo apt install percona-toolkit
```

### Image Processing Libraries

Install the required dependencies:

```bash
sudo apt update && sudo apt install -y \
  build-essential libxslt-dev libxml2-dev \
  imagemagick libvips-dev ffmpeg pdftk
```

---

## Installation

### Ruby Gems (via Bundler)

```bash
gem install bundler
bundle install
gem install dotenv
```

### Node.js Packages

```bash
corepack enable
npm install
```

---

## Configuration

### Optional: Create `.env` file

Copy the example and fill in secrets (if needed):

```bash
cp .env.example .env
```

### SSL Certificates with `mkcert`

1. Install:

```bash
sudo apt install mkcert libnss3-tools
```

2. Install root CA and generate certs:

```bash
mkcert -install
bin/generate_ssl_certificates
```

---

## Running Locally

### Start Docker services

```bash
LOCAL_DETACHED=true make local
```

### Start the app

In a **new terminal**:

```bash
sudo apt install libxslt-dev libxml2-dev
bin/rails db:prepare
bin/dev
```

Visit: [https://gumroad.dev](https://gumroad.dev)

---

## Development

### Logging In

Use:

- **Email:** `seller@gumroad.com`
- **Password:** `password`
- **2FA:** `000000`

See [Users & authentication](../users.md) for other roles.

### Reset Elasticsearch Indices

Run in Rails console:

```ruby
DevTools.delete_all_indices_and_reindex_all
```

---

## Common Tasks

### Rails Console

```bash
bin/rails c
```

### Rake Tasks

```bash
bin/rake <task_name>
```

---

## Linting

We use ESLint (JS) and RuboCop (Ruby). You can enable pre-commit hooks:

```bash
git config --local core.hooksPath .githooks
```

---

## 🛑 Fixing HTTPS or Privacy Warnings in Chrome

- On `Your connection is not private`, type: `thisisunsafe`
- To clear HSTS:

  - Go to `chrome://net-internals/#hsts`
  - Under **Delete domain security policies**, enter `gumroad.dev`

---

## 🧭 /etc/hosts Setup

Make sure this line is in your `/etc/hosts`:

```bash
127.0.0.1 gumroad.dev
```

```bash
sudo nano /etc/hosts
```

---

## ✅ Final Tips

- Use **WSL Ubuntu only**, never PowerShell or CMD.
- Use the versions from `.ruby-version` and `.node-version`.
- If port `:8080` is occupied, kill the process:

```bash
sudo lsof -i :8080
kill -9 <PID>
```

- Ensure the following environment variable is set (for seller login):

```
HELPER_WIDGET_SECRET=<any random string>
```
