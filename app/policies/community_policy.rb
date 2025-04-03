# frozen_string_literal: true

class CommunityPolicy < ApplicationPolicy
  def index?
    user.accessible_communities_ids.any? || (Feature.active?(:communities, user) && !user.is_buyer?)
  end

  def show?
    user.accessible_communities_ids.include?(record.id)
  end
end
