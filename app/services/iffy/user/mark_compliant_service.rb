# frozen_string_literal: true

class Iffy::User::MarkCompliantService
  attr_reader :user

  def initialize(user_id)
    @user = User.find_by_external_id!(user_id)
  end

  def perform
    user.mark_compliant!(author_name: "Iffy")
  end
end
