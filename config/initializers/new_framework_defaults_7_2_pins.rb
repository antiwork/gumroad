# frozen_string_literal: true

# Owner: gumclaw; audit regex-heavy validators before imposing a global timeout.
Regexp.timeout = nil

# Owner: gumclaw; audit Active Job callers before changing transaction enqueue timing.
ActiveJob::Base.enqueue_after_transaction_commit = false

# to_time_preserves_timezone stays :offset until step 3; ignore the boot warning.
