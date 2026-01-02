# frozen_string_literal: true

module User::LowBalanceFraudCheck
  extend ActiveSupport::Concern

  LOW_BALANCE_THRESHOLD = -100_00 # USD -$100 (triggers probation)
  private_constant :LOW_BALANCE_THRESHOLD

  HIGH_BALANCE_THRESHOLD = 100_00 # USD +$100 (removes probation)
  private_constant :HIGH_BALANCE_THRESHOLD

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

  def check_for_high_balance_and_remove_low_balance_probation
    return if unpaid_balance_cents <= HIGH_BALANCE_THRESHOLD
    return if !on_probation?

    probation_comment = most_recent_low_balance_probation_comment
    return if probation_comment.nil?

    revert_to_previous_risk_state!(probation_comment)
  end

  private
    def disable_refunds_and_put_on_probation!
      previous_state = user_risk_state

      disable_refunds!

      content = "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity"
      self.put_on_probation(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)

      probation_comment = comments.with_type_on_probation
                                  .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
                                  .order(created_at: :desc)
                                  .first
      probation_comment&.update!(json_data: probation_comment.json_data.merge("previous_risk_state" => previous_state))
    end

    def recently_probated_for_low_balance?
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .where("created_at > ?", LOW_BALANCE_PROBATION_WAIT_TIME.ago)
              .exists?
    end

    def most_recent_low_balance_probation_comment
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .order(created_at: :desc)
              .first
    end

    def revert_to_previous_risk_state!(probation_comment)
      previous_state = probation_comment.json_data["previous_risk_state"] || "compliant"
      content = "Probation removed automatically on #{Time.current.to_fs(:formatted_date_full_month)} because balance exceeded $100"

      case previous_state
      when "not_reviewed"
        mark_not_reviewed!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
        enable_refunds!
      else
        mark_compliant!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
      end
    end
end
