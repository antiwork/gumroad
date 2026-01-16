# PowerShell script to stop Gumroad Docker setup
# Usage: .\docker-stop.ps1

Write-Host "🛑 Stopping Gumroad Docker services..." -ForegroundColor Yellow

# Check for Docker Compose
if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Error: Docker is not installed!" -ForegroundColor Red
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
        exit 1
    }
}

$env:COMPOSE_PROJECT_NAME = "gumroad"
Invoke-Expression "$COMPOSE_CMD -f docker/docker-compose-all-in-one.yml down"
