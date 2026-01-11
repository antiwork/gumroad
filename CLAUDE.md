# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Before Key Actions

Re-read this file and `.github/PULL_REQUEST_TEMPLATE.md` before:
- Creating commits
- Creating pull requests

Before committing or pushing, provide the test command for the user to run and screenshot:
```bash
bundle exec rspec path/to/spec_file.rb
```

## Common Commands

```bash
# Start development server (Rails + Webpack + Sidekiq + AnyCable)
bin/dev

# Start Docker services (MySQL, Redis, Elasticsearch, etc.)
make local

# Run all tests
bundle exec rspec

# Run a single test file
bundle exec rspec spec/models/user_spec.rb

# Run a specific test by line number
bundle exec rspec spec/models/user_spec.rb:42

# Rails console
bin/rails c

# Linting
npm run lint        # JavaScript/TypeScript
bundle exec rubocop # Ruby
```

## Architecture Overview

### Backend (Rails)
- **Models** (`app/models/`): ActiveRecord models with concerns in `app/models/concerns/`
- **Controllers** (`app/controllers/`): Handle HTTP requests, often using Pundit policies
- **Services** (`app/services/`): Business logic extracted from models/controllers
- **Sidekiq Jobs** (`app/sidekiq/`): Background job processors (NOT `app/jobs/`)
- **Presenters** (`app/presenters/`): View presentation logic
- **Policies** (`app/policies/`): Pundit authorization policies
- **Modules** (`app/modules/`): Legacy location - don't create new files here

### Frontend (React + Inertia.js)
- **Pages** (`app/javascript/pages/`): Inertia.js page components
- **Components** (`app/javascript/components/`): Reusable React components
- **Hooks** (`app/javascript/hooks/`): Custom React hooks
- **Utils** (`app/javascript/utils/`): Utility functions

### Key Patterns
- Uses Inertia.js for React/Rails integration (no separate API)
- State machines via `state_machines-activerecord` gem
- Feature flags for new features
- VCR cassettes for external API testing

## Sidekiq Jobs

- Name jobs with `Job` suffix (not `Worker`)
- Queue priority: `critical` > `default` > `low` > `mongo`
- Use `queue: :low` for most background work, `default` if time-sensitive
- Use `lock: :until_executed` for idempotency
- Do NOT use `on_conflict: :replace` (slow, can break Sidekiq)

## Code Style

- Use `product` instead of `link` in new code
- Use `buyer` and `seller` instead of `customer` and `creator`
- Avoid `unless`
- No explanatory comments in code
- Sentence case for headers/buttons, not title case
- Use Nano IDs for external/public IDs
- Use `find_each` for batch processing large datasets

## Testing

- Don't use "should" in test descriptions
- Use `@example.com` for emails in tests
- Use `example.com`, `example.org`, `example.net` for custom domains
- Avoid `to_not have_enqueued_sidekiq_job` - use `SidekiqWorkerName.jobs.size` instead
- Use factories for test data

## Pull Requests

- Keep PRs under 1k lines, aim for ~100 loc
- After reviews begin, avoid force-pushing

### PR Body Format
```markdown
Issue: #[number]

# Description
## Problem
[What's broken or missing]

## Solution
[How you fixed it]

---
# Before/After
[Screenshots/videos for UI changes, or "Backend-only change"]

---
# Test Results
[Paste test output or screenshot]

---
# Checklist
- [ ] I have read the contributing guidelines
- [ ] I have watched Gumroad PR review livestreams
- [ ] I have performed a self-review and left review comments on my PR
- [ ] I have added/updated tests for my changes

---
# AI Disclosure
AI (Claude Code) was used for:
- [specific task 1]
- [specific task 2]
```

### Self-Review Comments
After creating a PR, **always** add self-review comments on specific lines of code explaining key design decisions. This is required before the PR is ready for maintainer review.

**What to comment on:**
- Why you chose a particular approach (e.g., `find_by` vs `find`)
- Non-obvious implementation choices (e.g., return value checking patterns)
- Why code is triggered in a specific location
- Performance considerations (e.g., adding indexes, using `find_each`)
- How the change relates to existing patterns in the codebase

**Command to add comments:**
```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -f body="Comment explaining the decision" \
  -f path="path/to/file.rb" \
  -F line=15 \
  -f side="RIGHT" \
  -f commit_id="$(git rev-parse HEAD)"
```

**Example comment:** "Using `find_by` instead of `find` because this worker is triggered asynchronously - the user could have been deleted between when the job was enqueued and when it runs."

## Commit Messages

Use conventional commit format with AI disclosure:
```
feat(scope): description

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`
