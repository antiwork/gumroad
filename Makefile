.PHONY: docker-start docker-stop docker-restart docker-logs docker-shell docker-clean help

# Docker Compose command (defaults to docker compose, falls back to docker-compose)
DOCKER_COMPOSE_CMD = $(shell command -v docker-compose 2>/dev/null || docker compose)
COMPOSE_PROJECT_NAME = gumroad

# All-in-one Docker setup - makes it super easy to get Gumroad running
docker-start:
	@echo "🚀 Starting Gumroad with Docker (all-in-one setup)..."
	@echo ""
	@echo "This will start all services:"
	@echo "  - MySQL database"
	@echo "  - Redis cache"
	@echo "  - MongoDB"
	@echo "  - Elasticsearch"
	@echo "  - Memcached"
	@echo "  - Rails app"
	@echo "  - Nginx (HTTPS on https://gumroad.dev)"
	@echo ""
	@echo "First run may take a few minutes to build..."
	@echo ""
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-all-in-one.yml up --build

docker-stop:
	@echo "🛑 Stopping Gumroad Docker services..."
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-all-in-one.yml down

docker-restart: docker-stop docker-start

docker-logs:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-all-in-one.yml logs -f

docker-shell:
	@echo "🐚 Opening shell in app container..."
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-all-in-one.yml exec app bash

docker-clean:
	@echo "🧹 Cleaning Docker volumes and containers..."
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-all-in-one.yml down -v

help:
	@echo "Gumroad Docker Commands:"
	@echo ""
	@echo "  make docker-start   - Start all services (default/recommended method)"
	@echo "  make docker-stop    - Stop all services"
	@echo "  make docker-restart - Restart all services"
	@echo "  make docker-logs    - View logs from all services"
	@echo "  make docker-shell   - Open bash shell in app container"
	@echo "  make docker-clean   - Stop and remove all volumes (clean start)"
	@echo ""
	@echo "After starting, Gumroad will be available at:"
	@echo "  - https://gumroad.dev (add to /etc/hosts: 127.0.0.1 gumroad.dev)"
