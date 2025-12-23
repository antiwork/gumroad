# frozen_string_literal: true

class UpdateSellerRefundEligibilityJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    unpaid_balance_cents = user.unpaid_balance_cents

    if unpaid_balance_cents > 0
      if user.refunds_disabled?
        user.enable_refunds!
      end

      if user.can_recover_from_low_balance_probation?(unpaid_balance_cents)
        user.restore_user_risk_state_before_probation!
      end
    elsif unpaid_balance_cents < User::LowBalanceFraudCheck::LOW_BALANCE_THRESHOLD_IN_CENTS && !user.refunds_disabled?
      user.disable_refunds!
    end
  end

  RetryHandler = ->(count, exception, msg) do
    case exception
    when User::LowBalanceFraudCheck::InvalidRecoveryStateError
      Rails.logger.error("[UpdateSellerRefundEligibilityJob] Discarding job on #{(count + 1).ordinalize} attempt for invalid recovery state: #{exception.message}")
      Bugsnag.notify(exception)
      :discard
    end
  end

  sidekiq_retry_in(&RetryHandler)
end
