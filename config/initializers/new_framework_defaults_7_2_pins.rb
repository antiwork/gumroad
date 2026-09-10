# frozen_string_literal: true

# Owner: gumclaw; audit regex-heavy validators before imposing a global timeout.
Regexp.timeout = nil

# Rails 8.0 deprecates config.active_job.enqueue_after_transaction_commit. The
# ActiveJob::Base default is already false (former :never). Pin on the class so
# boots stay quiet while callers are still audited before flipping the timing.
# Owner: gumclaw; audit Active Job callers before changing transaction enqueue timing.
ActiveJob::Base.enqueue_after_transaction_commit = false

# Expected boot deprecation under load_defaults 7.2: to_time_preserves_timezone
# stays :offset until rails-step-3 (#7567) sets it explicitly. Do not chase this
# warning during the Rails 8.0 soak.
