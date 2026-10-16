# frozen_string_literal: true

class CommunityPolicy < ApplicationPolicy
  def index?
    user.has_accessible_communities?
  end

  def show?
    user.accessible_communities_ids.include?(record.id)
  end
end
