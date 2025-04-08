# frozen_string_literal: true

class CommunityPolicy < ApplicationPolicy
  def index?
    user.accessible_communities_ids.any?
  end

  def show?
    user.accessible_communities_ids.include?(record.id)
  end
end
