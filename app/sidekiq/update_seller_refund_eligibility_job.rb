# frozen_string_literal: true

class UpdateSellerRefundEligibilityJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    unpaid_balance_cents = user.unpaid_balance_cents

    if unpaid_balance_cents > 0 && user.refunds_disabled?
      user.enable_refunds!
    elsif unpaid_balance_cents < User::LowBalanceFraudCheck::LOW_BALANCE_THRESHOLD && !user.refunds_disabled?
      user.disable_refunds!
    end

    user.restore_risk_state_if_balance_recovered!(unpaid_balance_cents)
  end
end
