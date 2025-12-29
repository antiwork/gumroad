# Docker Development Guide

This guide covers the unified Docker development setup for Gumroad. All services run in Docker containers, providing a consistent development environment with zero local dependencies beyond Docker itself.

## Overview

The development environment consists of:

- **Application services**: Rails server, webpack dev server, Sidekiq, AnyCable (RPC and WebSocket)
- **Data services**: MySQL, Redis, MongoDB, Elasticsearch
- **Storage**: MinIO (S3-compatible object storage)
- **Proxy**: Nginx (reverse proxy with SSL termination)

All services are defined in `docker/docker-compose.dev.yml` and can be managed with simple `make` commands.

## Quick Start

1. **Build development images** (first time only):

   ```bash
   make dev-build
   ```

2. **Start all services**:

   ```bash
   make dev
   ```

3. **Access the application**:
   - Open `https://gumroad.dev` in your browser
   - Accept the self-signed certificate warning (see [SSL Certificates](#ssl-certificates) below)

That's it! The database is automatically set up, and all services are ready to use.

## SSL Certificates

### Automatic Generation

SSL certificates are automatically generated inside Docker containers when you first run `make dev`. The certificates are:

- **Self-signed** (not from a trusted Certificate Authority)
- **Generated using openssl** (no external tools needed)
- **Valid for 1 year**
- **Stored in** `docker/local-nginx/certs/`

### Browser Security Warnings

Since the certificates are self-signed, browsers will show a security warning. This is **normal and expected** for development environments.

**To proceed:**

1. Click "Advanced" or "Show Details"
2. Click "Proceed to gumroad.dev" (or similar option)
3. The browser will remember your choice for future visits

**Common browser messages:**

- Chrome/Edge: "Your connection is not private" → "Advanced" → "Proceed to gumroad.dev (unsafe)"
- Firefox: "Warning: Potential Security Risk Ahead" → "Advanced" → "Accept the Risk and Continue"
- Safari: "This connection is not private" → "Show Details" → "visit this website"

### Regenerating Certificates

If you need to regenerate certificates:

```bash
make dev-clean-certs
make dev
```

## Common Commands

### Starting and Stopping

```bash
# Start all services (foreground)
make dev

# Start all services (background)
make dev-build
docker compose -f docker/docker-compose.dev.yml up -d

# Stop all services
make dev-down

# View logs (all services)
make dev-logs

# View logs (specific service)
docker compose -f docker/docker-compose.dev.yml logs -f web
docker compose -f docker/docker-compose.dev.yml logs -f webpack
```

### Accessing Services

```bash
# Open a shell in the web container
make dev-shell

# Run Rails console
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rails c

# Run Rake tasks
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rake task_name

# Run database migrations
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rails db:migrate
```

### Rebuilding Images

```bash
# Rebuild all development images
make dev-build

# Rebuild a specific service
docker compose -f docker/docker-compose.dev.yml build web
```

## Service Details

### Application Services

- **web**: Rails server on port 3000
- **webpack**: Webpack dev server on port 3035 (HTTPS)
- **webpack-ssr**: Webpack SSR watcher
- **sidekiq**: Background job processor
- **anycable_rpc**: AnyCable RPC server on port 50051
- **anycable_ws**: AnyCable WebSocket server on port 8080

### Data Services

- **db**: MySQL 8.0.32 on port 3306
- **redis**: Redis 7.0.7 on port 6379
- **mongo**: MongoDB 3.6.16 on port 27017
- **elasticsearch**: Elasticsearch 7.9.3 on port 9200

### Storage

- **minio**: MinIO S3-compatible storage
  - API: `http://localhost:9000`
  - Console: `http://localhost:9001` (minioadmin/minioadmin)

### Proxy

- **nginx**: Reverse proxy
  - HTTP: `http://localhost:80` (redirects to HTTPS)
  - HTTPS: `https://localhost:443`
  - AnyCable: `https://localhost:8081`

## Volume Mounts

Code is mounted as volumes for hot reloading:

- **Application code**: `/app` (mounted from repository root)
- **SSL certificates**: `/certs` (mounted from `docker/local-nginx/certs/`)

Changes to your code are immediately reflected in the containers without rebuilding.

## Environment Variables

Development environment variables are set in `docker/docker-compose.dev.yml`. Key variables:

- `RAILS_ENV=development`
- `DATABASE_HOST=db`
- `REDIS_HOST=redis:6379/0`
- `ELASTICSEARCH_HOST=http://elasticsearch:9200`

To override or add variables, create a `.env` file in the repository root or use Docker Compose environment files.

## Troubleshooting

### Services won't start

**Check if ports are already in use:**

```bash
# Check for processes using ports
lsof -i :3000
lsof -i :3306
lsof -i :6379
```

**Check Docker logs:**

```bash
make dev-logs
```

### Database connection errors

**Wait for database to be ready:**
The entrypoint script automatically waits for the database, but if you see connection errors:

```bash
# Check database health
docker compose -f docker/docker-compose.dev.yml ps db

# View database logs
docker compose -f docker/docker-compose.dev.yml logs db
```

### SSL certificate issues

**Certificates not generating:**

```bash
# Check certificate directory permissions
ls -la docker/local-nginx/certs/

# Regenerate certificates
make dev-clean-certs
make dev
```

**Browser still shows errors after accepting:**

- Clear browser cache and cookies for `gumroad.dev`
- Try an incognito/private window
- Check that certificates exist: `ls docker/local-nginx/certs/`

### Code changes not reflecting

**Check volume mounts:**

```bash
# Verify code is mounted
docker compose -f docker/docker-compose.dev.yml exec web ls -la /app
```

**Restart the service:**

```bash
docker compose -f docker/docker-compose.dev.yml restart web
```

### Performance issues

**Docker Desktop resource limits:**

- Increase CPU and memory allocation in Docker Desktop settings
- Recommended: 4+ CPU cores, 8GB+ RAM

**Volume mount performance (macOS):**

- Use Docker Desktop's file sharing settings
- Consider using `:cached` or `:delegated` mount options (advanced)

### Container won't start

**Check container logs:**

```bash
docker compose -f docker/docker-compose.dev.yml logs web
```

**Rebuild the image:**

```bash
make dev-build
```

**Clean up and start fresh:**

```bash
make dev-down
docker compose -f docker/docker-compose.dev.yml build --no-cache web
make dev
```

## Advanced Usage

### Running specific services

```bash
# Start only database services
docker compose -f docker/docker-compose.dev.yml up db redis mongo

# Start only application services
docker compose -f docker/docker-compose.dev.yml up web webpack sidekiq
```

### Accessing service logs

```bash
# All services
make dev-logs

# Specific service
docker compose -f docker/docker-compose.dev.yml logs -f web
docker compose -f docker/docker-compose.dev.yml logs -f webpack
docker compose -f docker/docker-compose.dev.yml logs -f sidekiq
```

### Database access

```bash
# MySQL client
docker compose -f docker/docker-compose.dev.yml exec db mysql -uroot -ppassword

# Redis client
docker compose -f docker/docker-compose.dev.yml exec redis redis-cli

# MongoDB shell
docker compose -f docker/docker-compose.dev.yml exec mongo mongosh
```

### Running tests

Tests can be run inside the Docker container:

```bash
# Run all tests
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rspec

# Run specific test file
docker compose -f docker/docker-compose.dev.yml exec web bundle exec rspec spec/models/user_spec.rb
```

## File Structure

```
docker/
├── dev/
│   ├── Dockerfile              # Development Docker image
│   ├── entrypoint.sh          # Container entrypoint script
│   └── generate_certificates.sh # SSL certificate generation
├── docker-compose.dev.yml     # Development compose configuration
└── local-nginx/
    ├── gumroad_dev.conf       # Nginx configuration
    └── certs/                 # SSL certificates (auto-generated)
```

## Additional Resources

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Docker Desktop Documentation](https://docs.docker.com/desktop/)
- [Main README](../README.md) for general project information
