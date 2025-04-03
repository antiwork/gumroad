<p align="center">
  <img src="https://public-files.gumroad.com/logo/gumroad.svg" height="100" alt="Gumroad logo">
</p>

<p align="center">
  <strong>Sell your stuff. See what sticks.</strong>
</p>

<p align="center">
  <a href="./LICENSE.md">License</a> •
  <a href="./CODE_OF_CONDUCT.md">Code of Conduct</a> •
  <a href="./CONTRIBUTING.md">Contributing</a> •
  <a href="#community">Community</a>
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
- [Community](#community)

## Getting Started

### Prerequisites

Before you begin, ensure you have the following installed:

#### Ruby

- https://www.ruby-lang.org/en/documentation/installation/
- Install the version listed in [the .ruby-version file](./.ruby-version)

#### Node.js

- https://nodejs.org/en/download

#### Docker & Docker Compose

We use `docker` and `docker compose` to setup the services for development environment.

- For MacOS: Grab the docker mac installation from the [Docker website](https://www.docker.com/products/docker-desktop)
- For Linux:
