# frozen_string_literal: true

module User::LowBalanceFraudCheck
  extend ActiveSupport::Concern

  class InvalidRecoveryStateError < StandardError; end

  LOW_BALANCE_THRESHOLD_IN_CENTS = -100_00 # USD -100

  LOW_BALANCE_RECOVERY_THRESHOLD_IN_CENTS = 100_00 # USD 100
  private_constant :LOW_BALANCE_RECOVERY_THRESHOLD_IN_CENTS

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
    return if unpaid_balance_cents > LOW_BALANCE_THRESHOLD_IN_CENTS

    AdminMailer.low_balance_notify(id, refunded_or_disputed_purchase_id).deliver_later

    disable_refunds_and_put_on_probation! unless recently_probated_for_low_balance? || suspended?
  end

  def restore_user_risk_state_before_probation!
    previous_probation_paper_trail_version = find_latest_probation_paper_trail_version
    previous_risk_state = PaperTrail.serializer.load(previous_probation_paper_trail_version.object_changes).dig("user_risk_state").first

    raise InvalidRecoveryStateError, "Invalid previous state for recovery: #{previous_risk_state}" unless previous_risk_state.in?(["compliant", "not_reviewed"])

    content = "Risk state reverted to \"#{previous_risk_state.humanize}\" automatically on #{Time.current.to_fs(:formatted_date_full_month)} as balance has recovered to #{MoneyFormatter.format(LOW_BALANCE_RECOVERY_THRESHOLD_IN_CENTS, :usd, no_cents_if_whole: true, symbol: true)}"

    case previous_risk_state
    when "compliant"
      mark_compliant!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
    when "not_reviewed"
      mark_not_reviewed!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
    end
  end

  def can_recover_from_low_balance_probation?(unpaid_balance_cents)
    return false if !self.on_probation?
    comments.with_type_on_probation
            .order(created_at: :desc)
            .first&.author_name == LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME &&
            unpaid_balance_cents >= LOW_BALANCE_RECOVERY_THRESHOLD_IN_CENTS
  end

  private
    def find_latest_probation_paper_trail_version
      versions
        .where("JSON_EXTRACT(object_changes, '$.user_risk_state[1]') = ?", "on_probation")
        .order(:created_at)
        .last
    end

    def disable_refunds_and_put_on_probation!
      disable_refunds!

      content = "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity"
      self.put_on_probation(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
    end

    def recently_probated_for_low_balance?
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .where("created_at > ?", LOW_BALANCE_PROBATION_WAIT_TIME.ago)
              .exists?
    end
end
