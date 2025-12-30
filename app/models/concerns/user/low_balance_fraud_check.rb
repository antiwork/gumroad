# frozen_string_literal: true

module User::LowBalanceFraudCheck
  extend ActiveSupport::Concern

  LOW_BALANCE_THRESHOLD = -100_00 # USD -100
  private_constant :LOW_BALANCE_THRESHOLD

  RECOVERY_THRESHOLD = 100_00 # USD 100
  private_constant :RECOVERY_THRESHOLD

  LOW_BALANCE_PROBATION_WAIT_TIME = 2.months
  private_constant :LOW_BALANCE_PROBATION_WAIT_TIME

  LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME = "LowBalanceFraudCheck"
  private_constant :LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME

  def enable_refunds!
    self.refunds_disabled = false
    save!
  end

  def disable_refunds!
    self.refunds_disabled = true
    save!
  end

  def check_for_low_balance_and_probate(refunded_or_disputed_purchase_id)
    return if unpaid_balance_cents > LOW_BALANCE_THRESHOLD

    AdminMailer.low_balance_notify(id, refunded_or_disputed_purchase_id).deliver_later

    disable_refunds_and_put_on_probation! unless recently_probated_for_low_balance? || suspended?
  end

  def check_for_probation_recovery!
    return unless on_probation?
    return unless unpaid_balance_cents > RECOVERY_THRESHOLD
    return unless probated_for_low_balance?

    enable_refunds!
    mark_compliant(
      author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME,
      content: "Recovered from LowBalanceFraudCheck probation automatically (balance > $100)."
    )
  end

  def probated_for_low_balance?
    last_probation_comment = comments.with_type_on_probation.last
    last_probation_comment&.author_name == LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME
  end

  private
    def disable_refunds_and_put_on_probation!
      disable_refunds!

      content = "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity"
      self.put_on_probation(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content: content)
    end

    def recently_probated_for_low_balance?
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .where("created_at > ?", LOW_BALANCE_PROBATION_WAIT_TIME.ago)
              .exists?
    end
end
