# frozen_string_literal: true

class UpdateSellerRefundEligibilityJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    unpaid_balance_cents = user.unpaid_balance_cents

    if unpaid_balance_cents > 0 && user.refunds_disabled?
      user.enable_refunds!
    elsif unpaid_balance_cents < -10000 && !user.refunds_disabled?
      user.disable_refunds!
    end

    # Auto-remove LowBalanceFraudCheck probation when balance exceeds $100
    if unpaid_balance_cents > 100_00 && user.on_probation? && was_probated_by_low_balance_fraud_check?(user)
      user.mark_compliant!(author_name: User::LowBalanceFraudCheck::LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
    end
  end

  private

  def was_probated_by_low_balance_fraud_check?(user)
    user.comments
        .with_type_on_probation
        .where(author_name: User::LowBalanceFraudCheck::LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
        .exists?
  end
end
