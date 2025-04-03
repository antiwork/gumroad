# frozen_string_literal: true

module Balance::RefundEligibilityUnderwriter
  extend ActiveSupport::Concern

  included do
    after_commit :update_seller_refund_eligibility
  end

  private
    def update_seller_refund_eligibility
      return if user_id.blank?
      return unless anticipate_refund_eligibility_changes?

      UpdateSellerRefundEligibilityJob.perform_async(user_id)
    end

    def anticipate_refund_eligibility_changes?
      return unless amount_cents_previously_changed?

      before = amount_cents_previously_was || 0
      after = amount_cents

      balance_increased = before < after
      balance_decreased = before > after

      return true if balance_increased && user.refunds_disabled?
      return true if balance_decreased && !user.refunds_disabled?

      false
    end
end
