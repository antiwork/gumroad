## What

Configure Sentry for error monitoring alongside Bugsnag, and introduce an `ErrorNotifier` abstraction that sends to both.

**Changes:**
- Add `sentry-ruby` and `sentry-rails` gems
- Add Sentry initializer (`config/initializers/sentry.rb`) with DSN from GlobalConfig, 1% trace sampling, and sensible exception exclusions
- Add `ErrorNotifier` service that wraps both `Bugsnag.notify` and `Sentry.capture_exception`/`capture_message`, including support for severity, metadata, and block-style reporting
- Replace all ~60 `Bugsnag.notify` calls across the codebase with `ErrorNotifier.notify`

## Why

Adds Sentry as a second error monitoring backend. The `ErrorNotifier` abstraction means we can eventually drop Bugsnag without touching callsites again. Running both in parallel lets us validate Sentry coverage before committing to the switch.

Closes #199
