# frozen_string_literal: true

class CommunityChatMessagePolicy < ApplicationPolicy
  def update?
    user.id == record.user_id
  end

  def destroy?
    user.id == record.user_id || user.id == record.community.seller_id
  end
end
