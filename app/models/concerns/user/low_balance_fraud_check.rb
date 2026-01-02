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

  def check_for_high_balance_and_remove_low_balance_probation!
    return unless unpaid_balance_cents > HIGH_BALANCE_THRESHOLD
    return unless on_probation?
    return unless should_auto_remove_probation?

    revert_to_previous_risk_state!
  end

  private
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

    def should_auto_remove_probation?
      low_balance_probation_comment = most_recent_low_balance_probation_comment
      return false if low_balance_probation_comment.nil?

      !has_newer_risk_state_transition?(low_balance_probation_comment)
    end

    def most_recent_low_balance_probation_comment
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .order(created_at: :desc)
              .first
    end

    def has_newer_risk_state_transition?(probation_comment)
      comments.where(comment_type: Comment::RISK_STATE_COMMENT_TYPES)
              .where("id > ?", probation_comment.id)
              .exists?
    end

    def revert_to_previous_risk_state!
      previous_state = previous_risk_state_from_paper_trail
      return if previous_state.in?(%w[flagged_for_fraud flagged_for_tos_violation])

      content = "Probation removed automatically on #{Time.current.to_fs(:formatted_date_full_month)} because balance exceeded $100"

      case previous_state
      when "compliant"
        mark_compliant!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
      else
        mark_not_reviewed!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
        enable_refunds!
      end
    end

    def previous_risk_state_from_paper_trail
      probation_version = versions.where("JSON_CONTAINS(object_changes, ?, '$.user_risk_state')", '"on_probation"')
                                  .order(created_at: :desc)
                                  .first
      return "not_reviewed" if probation_version.nil?

      changeset = probation_version.changeset
      return "not_reviewed" if changeset.nil? || !changeset.key?("user_risk_state")

      changeset["user_risk_state"].first || "not_reviewed"
    end
end
