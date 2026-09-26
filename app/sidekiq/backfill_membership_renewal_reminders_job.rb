# frozen_string_literal: true

class BackfillMembershipRenewalRemindersJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform
    Onetime::BackfillMembershipRenewalReminders.process
  end
end
