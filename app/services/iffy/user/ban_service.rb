# frozen_string_literal: true

class Iffy::User::BanService
  attr_reader :user

  def initialize(id)
    @user = User.find_by_external_id!(id)
  end

  def perform
    ActiveRecord::Base.transaction do
      reason = "General non-compliance"
      user.update!(tos_violation_reason: reason)
      comment_content = "Banned for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} (#{reason})"
      user.flag_for_tos_violation!(author_name: "Iffy", content: comment_content, bulk: true) unless user.flagged_for_tos_violation? || user.on_probation? || user.suspended?
      user.suspend_for_tos_violation!(author_name: "Iffy", content: comment_content, bulk: true) unless user.suspended?
    end
  end
end
