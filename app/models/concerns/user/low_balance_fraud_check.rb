# frozen_string_literal: true

module User::LowBalanceFraudCheck
  extend ActiveSupport::Concern

  LOW_BALANCE_THRESHOLD = -100_00 # USD -100
  private_constant :LOW_BALANCE_THRESHOLD

  HIGH_BALANCE_THRESHOLD = 100_00 # USD 100
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

  # When a seller's balance recovers, automatically remove probation *only if*:
  # - probation was applied by LowBalanceFraudCheck
  # - no newer admin/system risk-state transition happened after that probation
  #
  # Restores to the pre-probation state (compliant / not_reviewed). If the
  # previous state can't be found, falls back to not_reviewed (default state).
  def check_for_high_balance_and_remove_low_balance_probation!
    return unless unpaid_balance_cents >= HIGH_BALANCE_THRESHOLD
    return unless on_probation?

    probation_comment = most_recent_low_balance_probation_comment
    return if probation_comment.nil?
    return if has_newer_risk_state_transition?(probation_comment)

    previous_state = previous_risk_state_before_low_balance_probation

    content = "Probation removed automatically on #{Time.current.to_fs(:formatted_date_full_month)} as balance has recovered to #{MoneyFormatter.format(HIGH_BALANCE_THRESHOLD, :usd, no_cents_if_whole: true, symbol: true)}"

    case previous_state
    when "compliant"
      mark_compliant!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
    when "not_reviewed"
      mark_not_reviewed!(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content:)
    else
      Bugsnag.notify(StandardError.new("Unknown previous risk state for LowBalanceFraudCheck recovery: #{previous_state.inspect} (user_id=#{id})"))
    end
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

    def most_recent_low_balance_probation_comment
      comments.with_type_on_probation
              .where(author_name: LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
              .order(created_at: :desc, id: :desc)
              .first
    end

    def has_newer_risk_state_transition?(probation_comment)
      comments.where(comment_type: Comment::RISK_STATE_COMMENT_TYPES)
              .where("id > ?", probation_comment.id)
              .exists?
    end

    def previous_risk_state_before_low_balance_probation
      probation_version = versions
        .where("JSON_UNQUOTE(JSON_EXTRACT(CAST(object_changes AS JSON), '$.user_risk_state[1]')) = ?", "on_probation")
        .order(created_at: :desc, id: :desc)
        .first

      return "not_reviewed" if probation_version.nil?

      changeset = probation_version.changeset
      return "not_reviewed" if changeset.nil? || !changeset.key?("user_risk_state")

      previous_state = changeset["user_risk_state"].first
      previous_state.presence || "not_reviewed"
    end
end
