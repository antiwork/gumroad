# frozen_string_literal: true

# Runs the one-time membership reminder backfill off-deploy:
#   BackfillMembershipRenewalRemindersJob.perform_async
#
# Inspect the blast radius first: pass dry_run: true to the service directly
# (Onetime::BackfillMembershipRenewalReminders.process(dry_run: true)).
#
# A rerun is refused by the service's Redis claim, so the lock is the guard, not
# the queue's until_executed (which only prevents concurrent runs).
class BackfillMembershipRenewalRemindersJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform
    Onetime::BackfillMembershipRenewalReminders.process
  end
end
