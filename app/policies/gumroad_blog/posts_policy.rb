# frozen_string_literal: true

class GumroadBlog::PostsPolicy < ApplicationPolicy
  allow_anonymous_user_access!

  def index?
    true
  end

  def show?
    return false unless record.alive?
    return false unless record.shown_on_profile?
    return false if record.workflow_id.present?
    return false unless record.audience_type?

    if !record.published?
      return false unless seller&.id == record.seller_id
    end

    true
  end
end
