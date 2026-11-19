# frozen_string_literal: true

class BackfillMembershipAdvanceRenewalRemindersJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  # Past the first deploy that scheduled the notice at charge time; the worker dedupes per renewal, so overlap is harmless.
  ROLLOUT_FINISHED_AT = Time.utc(2026, 10, 27).freeze

  def perform
    Onetime::BackfillMembershipAdvanceRenewalReminders.process(rollout_finished_at: ROLLOUT_FINISHED_AT)
  end
end
