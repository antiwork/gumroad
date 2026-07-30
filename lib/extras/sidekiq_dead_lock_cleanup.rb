# frozen_string_literal: true

# Releases an `until_executed` lock when a job dies, so the lock cannot outlive the job and
# silently drop every later enqueue as a duplicate (gumroad-private#1576).
#
# Lives here rather than inline in the initializer so the spec can exercise the shipped handler:
# `Sidekiq.configure_server` only yields in a server process, so a test can never reach a lambda
# defined inside that block.
module SidekiqDeadLockCleanup
  # sidekiq-unique-jobs v7+ writes `lock_digest`; reading only the pre-v7 `unique_digest` made
  # this a no-op on v8. `delete_by_digest` is an instance method, not a class method.
  HANDLER = lambda do |job, _exception|
    digest = job[SidekiqUniqueJobs::LOCK_DIGEST]
    SidekiqUniqueJobs::Digests.new.delete_by_digest(digest) if digest
  end
end
