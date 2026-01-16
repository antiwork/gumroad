# Gumroad

## 🚀 Quick Start (Recommended: Docker)

The easiest way to get Gumroad running locally is with Docker. One command gets everything set up:

```bash
make docker-start
```

This starts all required services (MySQL, Redis, MongoDB, Elasticsearch, Memcached, Nginx, and the Rails app) and makes Gumroad available at **https://gumroad.dev**.

### First Time Setup

1. **Ensure Docker is installed**
   - [Docker Desktop](https://www.docker.com/products/docker-desktop/) for Mac/Windows
   - Docker Engine for Linux

2. **Add gumroad.dev to your hosts file**
   
   **macOS/Linux:** Edit `/etc/hosts`
   ```
   127.0.0.1 gumroad.dev
   ```
   
   **Windows:** Edit `C:\Windows\System32\drivers\etc\hosts`
   ```
   127.0.0.1 gumroad.dev
   ```

3. **Start Gumroad**
   
   **macOS/Linux (using Make):**
   ```bash
   make docker-start
   ```
   
   **Windows (PowerShell):**
   ```powershell
   .\docker-start.ps1
   ```
   
   **Or use Docker Compose directly:**
   ```bash
   docker compose -f docker/docker-compose-all-in-one.yml up --build
   ```

4. **Open in browser**
   - Navigate to https://gumroad.dev
   - Accept the self-signed SSL certificate warning (first time only)

That's it! Gumroad is now running with all services configured automatically.

### Docker Commands

**macOS/Linux (using Make):**
- `make docker-start` - Start all services
- `make docker-stop` - Stop all services
- `make docker-restart` - Restart all services
- `make docker-logs` - View logs from all services
- `make docker-shell` - Open bash shell in app container
- `make docker-clean` - Stop and remove all volumes (clean start)

**Windows (PowerShell):**
- `.\docker-start.ps1` - Start all services
- `.\docker-stop.ps1` - Stop all services
- `docker compose -f docker/docker-compose-all-in-one.yml logs -f` - View logs
- `docker compose -f docker/docker-compose-all-in-one.yml exec app bash` - Open shell in app container
- `docker compose -f docker/docker-compose-all-in-one.yml down -v` - Stop and remove all volumes

**Or use Docker Compose directly (all platforms):**
- `docker compose -f docker/docker-compose-all-in-one.yml up --build` - Start all services
- `docker compose -f docker/docker-compose-all-in-one.yml down` - Stop all services

### Troubleshooting

**Port already in use?**
- Stop other services using ports 80, 443, 3000, 3306, 6379, 27017, 9200, or 11211
- Or modify ports in `docker/docker-compose-all-in-one.yml`

**SSL certificate warning?**
- This is normal for local development
- The script auto-generates self-signed certificates
- Accept the warning in your browser

**Services won't start?**
- Check Docker Desktop is running
- Ensure you have enough disk space
- Try `make docker-clean` and restart

## 📋 Alternative Setup Methods

### Manual Setup (Advanced)

If you prefer not to use Docker, you can set up services manually. See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed instructions.

---

**Need help?** Check [CONTRIBUTING.md](CONTRIBUTING.md) or open an issue.
