# frozen_string_literal: true

class Admin::UserRiskStatePresenter
  RISK_STATE_COMMENT_TYPES = Comment::RISK_STATE_COMMENT_TYPES
  LAST_STATUS_CHANGED_AT_NOT_PROVIDED = Object.new
  private_constant :LAST_STATUS_CHANGED_AT_NOT_PROVIDED

  attr_reader :user, :last_status_changed_at_override

  def initialize(user, last_status_changed_at: LAST_STATUS_CHANGED_AT_NOT_PROVIDED)
    @user = user
    @last_status_changed_at_override = last_status_changed_at
  end

  def props
    {
      status:,
      user_risk_state: user.user_risk_state,
      suspended: user.suspended?,
      flagged_for_fraud: user.flagged_for_fraud?,
      flagged_for_tos_violation: user.flagged_for_tos_violation?,
      on_probation: user.on_probation?,
      compliant: user.compliant?,
      last_status_changed_at: last_status_changed_at&.as_json,
    }
  end

  private
    def status
      return "Suspended" if user.suspended?
      return "Flagged" if user.flagged?

      "Compliant"
    end

    def last_status_changed_at
      return last_status_changed_at_override unless last_status_changed_at_override.equal?(LAST_STATUS_CHANGED_AT_NOT_PROVIDED)

      if user.association(:comments).loaded?
        return user.comments.select { _1.comment_type.in?(RISK_STATE_COMMENT_TYPES) }.max_by(&:created_at)&.created_at
      end

      user.comments.where(comment_type: RISK_STATE_COMMENT_TYPES).order(created_at: :desc).first&.created_at
    end
end
