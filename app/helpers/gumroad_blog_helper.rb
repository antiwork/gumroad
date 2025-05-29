# frozen_string_literal: true

module GumroadBlogHelper
  def can_see_gumroad_blog?(user)
    user&.is_team_member? || Feature.active?(:gumroad_blog, user)
  end
end
