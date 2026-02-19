# frozen_string_literal: true

class Iffy::User::SuspendService
  attr_reader :user

  def initialize(id)
    @user = User.find_by_external_id!(id)
  end

  def perform
    return if !user.can_flag_for_tos_violation?

    ActiveRecord::Base.transaction do
      reason = "General non-compliance"
      user.update!(tos_violation_reason: reason)
      comment_content = "Suspended for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} (#{reason})"
      user.flag_for_tos_violation!(author_name: "Iffy", content: comment_content, bulk: true)
    end
  end
end
