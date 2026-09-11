# frozen_string_literal: true

class Settings::SocialConnectionsPolicy < ApplicationPolicy
  def show?
    user.role_owner_for?(seller)
  end
end
