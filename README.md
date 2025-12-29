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
  - [Running Locally](#running-locally)
- [Development](#development)
  - [Logging in](#logging-in)
  - [Resetting Elasticsearch indices](#resetting-elasticsearch-indices)
  - [Push Notifications](#push-notifications)
  - [Common Development Tasks](#common-development-tasks)
  - [Linting](#linting)

## Getting Started

### Prerequisites

> 💡 If you're on Windows, follow our [Windows setup guide](docs/development/windows.md) instead.

The only requirement is **Docker**. All dependencies (Ruby, Node.js, MySQL, Redis, etc.) run inside Docker containers.

#### Docker

- For MacOS: Download the Docker app from the [Docker website](https://www.docker.com/products/docker-desktop)
- For Linux:

```bash
sudo wget -qO- https://get.docker.com/ | sh
sudo usermod -aG docker $(whoami)
```

If you are on Linux, or installed Docker via a package manager on a mac, you may need to manually give docker superuser access to open ports 80 and 443. To do that, use `sudo` with the commands below.

### Configuration

#### Set up Custom credentials

App can be booted without any custom credentials. But if you would like to use services that require custom credentials (e.g. S3, Stripe, Resend, etc.), you can copy the `.env.example` file to `.env` and fill in the values.

#### SSL Certificates

SSL certificates are **automatically generated** inside Docker containers when you first run the development environment. The certificates are self-signed, which means:

- Browsers will show a security warning when you first visit `https://gumroad.dev`
- This is normal and expected for development environments
- To proceed, click "Advanced" → "Proceed to gumroad.dev" (or similar option in your browser)
- You may need to accept the certificate once per browser

If you need to regenerate certificates, run:

```bash
make dev-clean-certs
```

Then restart the development environment.

### Running Locally

#### First-time setup

Build the development Docker images:

```bash
make dev-build
```

This may take several minutes the first time as it downloads base images and installs dependencies.

#### Start the development environment

Start all services (Rails, webpack, Sidekiq, AnyCable, databases, etc.):

```bash
make dev
```

This command will:

- Automatically generate SSL certificates (if they don't exist)
- Start all required services (MySQL, Redis, MongoDB, Elasticsearch, MinIO, etc.)
- Start the Rails server, webpack dev server, Sidekiq, and AnyCable
- Set up the database automatically
- Run in the foreground (press Ctrl+C to stop)

You can now access the application at `https://gumroad.dev`.

#### Running in the background

To run services in the background:

```bash
make dev-build
docker compose -f docker/docker-compose.dev.yml up -d
```

To stop services:

```bash
make dev-down
```

For more information, see [Docker Development Guide](docs/development/docker.md).

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
make dev-shell
# Then inside the container:
bundle exec rails c
```

Or using docker compose directly:

```shell
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rails c
```

#### Rake tasks:

```shell
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rake task_name
```

#### View logs:

```shell
make dev-logs
```

#### Access container shell:

```shell
make dev-shell
```

Read more about [dev docker](docs/development/docker.md).

### Linting

We use ESLint for JS, and Rubocop for Ruby. Your editor should support displaying and fixing issues reported by these inline, and CI will automatically check and fix (if possible) these.

If you'd like, you can run `git config --local core.hooksPath .githooks` to check for these locally when committing.

## Common Issues

### macOS Error When Running Tests (Related to `fork()`)

```
objc[11912]: +[__NSCFConstantString initialize] may have been in progress in another thread when fork() was called.
objc[11912]: +[__NSCFConstantString initialize] may have been in progress in another thread when fork() was called. We cannot safely call it or ignore it in the fork() child process. Crashing instead. Set a breakpoint on objc_initializeAfterForkError to debug.
```

This issue occurs on macOS due to how the `fork()` system call interacts with multithreaded Objective-C applications—commonly triggered when Spring is enabled during testing.

#### How to Fix:

Temporarily disable Spring before running your tests to avoid this error.

```bash
export DISABLE_SPRING=1
bin/rspec spec/requests/balance_pages_spec.rb
```

This will disable Spring for the current session, allowing the tests to run without triggering the `fork()`-related crash.
