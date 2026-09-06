# Setting Up Production Environment

This document provides guidance on setting up and configuring the production environment for Gumroad, including environment variables and running services.

## Table of Contents

- [Environment Variables](#environment-variables)
- [Running Services](#running-services)
  - [Web Servers](#web-servers)
    - [Puma (Application Server)](#puma-application-server)
  - [Sidekiq Workers](#sidekiq-workers)
    - [Configuration](#configuration)
  - [Push Notification Service (RPush)](#push-notification-service-rpush)

## Environment Variables

Set up all environment variables listed in the `.env.production.example` file in your environment. These variables contain all the necessary configuration for database connections, caching, application servers, storage, payment processing, authentication, email services, and third-party integrations.

## Running Services

The Gumroad production environment consists of several services that work together. Below is information on how to run each service.

### Web Servers

Gumroad uses Puma as the application server.

#### Puma (Application Server)

Puma runs the Rails application and handles HTTP requests. Configuration:

- **Worker Processes**: Set via `PUMA_WORKER_PROCESSES` (default: 1)
- **Threads**: Set via `RAILS_MAX_THREADS` (default: 2)
- **Memory**: Recommended 2GB per instance

We recommend running Nginx in front of Puma as a reverse proxy.

### Sidekiq Workers

Sidekiq processes background jobs for the application.

#### Configuration

- **Threads**: Set via `RAILS_MAX_THREADS` (default: 2)
- **Memory**: Recommended 2GB per instance
- **Database Replicas**: Set `USE_DB_WORKER_REPLICAS=true` to use read replicas for database operations

### Push Notification Service (RPush)

RPush handles push notifications to mobile devices.

- Requires specific Redis instance configured via `RPUSH_REDIS_HOST`
- Requires certificates for Apple Push Notification Service (APN)
- Requires Firebase configuration for Android notifications
- **Memory**: Recommended 2GB per instance
- **Environment Variables**:
  - `INITIALIZE_RPUSH_APPS`: "true"
