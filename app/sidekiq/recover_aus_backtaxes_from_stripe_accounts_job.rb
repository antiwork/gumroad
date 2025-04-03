# frozen_string_literal: true

class RecoverAusBacktaxesFromStripeAccountsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform
    BacktaxAgreement
      .not_collected
      .where(jurisdiction: BacktaxAgreement::Jurisdictions::AUSTRALIA)
      .pluck(:user_id)
      .uniq
      .each { |creator_id| RecoverAusBacktaxFromStripeAccountJob.perform_async(creator_id) }
  end
end
