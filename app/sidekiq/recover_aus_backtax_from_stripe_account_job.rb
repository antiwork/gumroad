# frozen_string_literal: true

class RecoverAusBacktaxFromStripeAccountJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(creator_id)
    creator = User.find_by_id(creator_id)
    return unless creator.present?

    australia_backtax_agreement = creator.australia_backtax_agreement
    return unless australia_backtax_agreement.present?
    return if australia_backtax_agreement.collected?

    credit = australia_backtax_agreement.credit
    return unless credit.present?

    StripeChargeProcessor.debit_stripe_account_for_australia_backtaxes(credit:)
  end
end
