<p align="center">
  <picture>
    <source srcset="https://public-files.gumroad.com/logo/gumroad-dark.svg" media="(prefers-color-scheme: dark)">
    <source srcset="https://public-files.gumroad.com/logo/gumroad.svg" media="(prefers-color-scheme: light)">
    <img src="https://public-files.gumroad.com/logo/gumroad.svg" height="100" alt="Gumroad logo">
  </picture>
</p>

<p align="center">
  <strong>Sell your stuff. See what sticks.</strong>
</p>

<p align="center">
  <a href="https://gumroad.com">Gumroad</a> is an e-commerce platform that enables creators to sell products directly to consumers. This repository contains the source code for the Gumroad web application.
</p>

## Table of Contents

- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Configuration](#configuration)
  - [Running Locally](#running)
- [Development](#development)
  - [Logging in](#logging-in)
  - [Resetting Elasticsearch indices](#resetting-elasticsearch-indices)
  - [Push Notifications](#push-notifications)
  - [Common Development Tasks](#common-development-tasks)
  - [Linting](#linting)
  - [Troubleshooting](#troubleshooting)

## Getting Started

### Prerequisites

#### WSL (windows only)

In windows, you'll need to run ubuntu under [WSL](https://github.com/microsoft/WSL).

1. Open **PowerShell as Administrator** and run:

```bash
# One-time setup to avoid long file path issues in git
git config --system core.longpaths true

# install wsl
wsl --install
```

2. Restart if prompted.

3. Choose a non-root username and password in the Ubuntu setup.

4. Always launch **Ubuntu** for development work (not PowerShell or CMD).


#### Ruby, Node, and other system dependencies

The app requires Ruby, Node, and various other system packages. Ruby and Node need to be the specific versions listed in the `.ruby-version` and `.node-version`files. You can use the helper scripts to install them in local environments via `rbenv` and `nvm`.

For Ubuntu (and Windows, via WSL):

```
bin/install_deps_ubuntu.sh
```

For MacOS:
```
bin/install_deps_macos.sh
```

The scripts will also install various other system packages for the DB, image processing, and other utilities.

##### MacOS only
[pdftk](https://www.pdflabs.com/tools/pdftk-server/) for mac is available as a GUI installer, so is not installed by the script, and needs to be installed manually. [Download from here](https://www.pdflabs.com/tools/pdftk-the-pdf-toolkit/pdftk_server-2.02-mac_osx-10.11-setup.pkg). The domain may be blocked by Apple's firewall - if this happens, go to Settings > Privacy & Security and click "Open Anyways" to allow the installation.


#### Docker

We use Docker to setup the services for the development environment.

[Download and install docker desktop](https://www.docker.com/products/docker-desktop/) for your if you are using Windows or MacOS.

##### Windows only
On windows, you'll need to activate the WSL integration afterwards:
1. Download Docker Desktop: [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop)
2. Open Docker → ⚙️ → **Resources > WSL Integration**
3. Enable Ubuntu.
4. Ensure Docker Desktop shows **"Engine Running"**.

##### Ubuntu only

For ubuntu, it's more efficient to install just the docker engine. Follow [the official guide](https://docs.docker.com/engine/install/ubuntu/) for installing.

It's recommended that afterwards you add your user to the docker group, so that you don't need sudo to run docker commands:

```
sudo usermod -aG docker $(whoami)
```

You'll need to restart the shell after this step.


### Installation

If all the prerequisites are in place, you should have the correct version of Ruby, the bundler gem, npm and corepack. So simply run:

```
bundle install
npm install
```

### Configuration

#### Generate local SSL certificates

Run the helper script to generate local SSL certificates and add the to the root CA (these are necessary so that the browsers trust the development website):

```
mkcert -install
bin/generate_ssl_certificates
```

#### Initialize the database

```
bin/rails db:prepare
```

#### Set up custom credentials (optional)

App can be booted without any custom credentials. But if you would like to use services that require custom credentials (e.g. S3, Stripe, Resend, etc.), you can copy the .env.example file to .env and fill in the values.


### Running

You need to run the app and the docker services in parallel.

Start docker services in on terminal:

```
make local
```

And the app in another (this starts the Rails server, Webpack, and a Sidekiq worker):

```
bin/dev
```

You can alternatively also run the docker services in the background, so it all runs on the same terminal:
```
LOCAL_DETACHED=true make local
bin/dev
```

You can now access the application at https://gumroad.dev.


## Development

### Logging in

You can log in with the username `seller@gumroad.com` and the password `password`. The two-factor authentication code is `000000`.

Read more about logging in as a user with a different team role at [Users & authentication](docs/users.md).

### Resetting Elasticsearch indices

You will need to explicitly reindex Elasticsearch to populate the indices after setup, otherwise you will see `index_not_found_exception` errors when you visit the dev application. You can reset them using:

```ruby
# Run this in a rails console:
DevTools.delete_all_indices_and_reindex_all
```

### Push Notifications

To send push notifications:

```shell
INITIALIZE_RPUSH_APPS=true bundle exec rpush start -e development -f
```

### Common Development Tasks

#### Rails console:

```shell
bin/rails c
```

#### Rake tasks:

```shell
bin/rake task_name
```

### Linting

We use ESLint for JS, and Rubocop for Ruby. Your editor should support displaying and fixing issues reported by these inline, and CI will automatically check and fix (if possible) these.

If you'd like, you can run `git config --local core.hooksPath .githooks` to check for these locally when committing.


### Troubleshooting

If your browser is complaining about an HSTS error ("connection is not private", "thisisunsafe", "browser might be trying to impersonate you"), try :
  - Go to `chrome://net-internals/#hsts`
  - Under **Delete domain security policies**, enter `gumroad.dev`

---

If port `:8080` is occupied, kill the process:

```bash
sudo lsof -i :8080
kill -9 <PID>
```

