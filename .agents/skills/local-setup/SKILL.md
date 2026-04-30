---
name: local-setup
description: >
  Diagnose and repair Gumroad local development setup issues. Use when bin/dev, tests,
  Docker services, database setup, Redis, MongoDB, MySQL, Elasticsearch, Nginx, SSL, or
  gumroad.dev are failing locally, or when an agent needs to verify the local environment.
allowed-tools: Bash(bin/doctor *), Bash(git *), Bash(rg *), Bash(sed *), Bash(cat *), Bash(docker *), Bash(make *), Bash(bin/rails *), Bash(bundle exec rspec *)
---

# Local setup

Use `bin/doctor` as the deterministic probe for local setup state. The script derives expected values from repository sources of truth and prints which source each check used.

## Workflow

1. Read the relevant source of truth before proposing fixes:
   - `README.md` for the Docker-first local setup path
   - `.ruby-version` and `Gemfile.lock` for Ruby and Bundler versions
   - `.env.development` for service endpoints and credentials
   - `docker/docker-compose-local.yml` and `Makefile` for Docker services
   - `Procfile.dev` for app processes
   - `docker/local-nginx/gumroad_dev.conf` for local domains, SSL, and proxy ports
2. Run `bin/doctor` from the repo root.
3. Treat failed checks as current machine state, not application regressions, until the source files and probe output disagree.
4. Read the service-specific sections as the runtime source of truth. A service can be healthy outside Docker Compose when the `.env.development` endpoint check passes.
5. Prefer the Docker-first setup path from `README.md` when a required service is not available:

```bash
LOCAL_DETACHED=true make local
bin/rails db:prepare
bin/dev
```

6. If tests fail because seeded merchant accounts or local data are missing, run the setup command that creates them instead of changing factories:

```bash
RAILS_ENV=test bin/rails db:seed
```

## Rules

- Do not hardcode service ports, credentials, Ruby versions, or Bundler versions in new diagnostics. Derive them from the source files above.
- Derive the Docker Compose project name from `Makefile` so diagnostics match `make local`.
- Do not invoke clients in a way that can block on interactive prompts; redirect stdin or use non-interactive env vars when checking credentials.
- A green final verdict requires both the app URL to respond and all required checks to pass.
- If `bin/doctor` gives a misleading result, update it to derive from the correct source of truth and make the output state that source.
- Do not treat a stopped Docker Compose container as a problem when the matching service endpoint is reachable and the app responds.
- Keep local setup fixes separate from product behavior changes.
- Report the exact failing check, the source file it used, and the command that fixes it.
