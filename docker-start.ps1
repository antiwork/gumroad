# PowerShell script to start Gumroad Docker setup
# Usage: .\docker-start.ps1

Write-Host "🚀 Starting Gumroad with Docker (all-in-one setup)..." -ForegroundColor Green
Write-Host ""
Write-Host "This will start all services:" -ForegroundColor Cyan
Write-Host "  - MySQL database"
Write-Host "  - Redis cache"
Write-Host "  - MongoDB"
Write-Host "  - Elasticsearch"
Write-Host "  - Memcached"
Write-Host "  - Rails app"
Write-Host "  - Nginx (HTTPS on https://gumroad.dev)"
Write-Host ""
Write-Host "First run may take a few minutes to build..." -ForegroundColor Yellow
Write-Host ""

# Check for Docker Compose
if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Error: Docker is not installed!" -ForegroundColor Red
    Write-Host "Please install Docker Desktop: https://www.docker.com/products/docker-desktop" -ForegroundColor Yellow
    exit 1
}

# Try docker compose (v2) first, fall back to docker-compose (v1)
$COMPOSE_CMD = "docker compose"
$result = docker compose version 2>&1
if ($LASTEXITCODE -ne 0) {
    if (Get-Command "docker-compose" -ErrorAction SilentlyContinue) {
        $COMPOSE_CMD = "docker-compose"
    } else {
        Write-Host "❌ Error: Docker Compose is not installed!" -ForegroundColor Red
        Write-Host "Please install Docker Desktop: https://www.docker.com/products/docker-desktop" -ForegroundColor Yellow
        exit 1
    }
}

$env:COMPOSE_PROJECT_NAME = "gumroad"
Invoke-Expression "$COMPOSE_CMD -f docker/docker-compose-all-in-one.yml up --build"
