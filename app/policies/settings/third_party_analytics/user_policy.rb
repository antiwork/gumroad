# frozen_string_literal: true

class Settings::ThirdPartyAnalytics::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  def update?
    show?
  end
end
