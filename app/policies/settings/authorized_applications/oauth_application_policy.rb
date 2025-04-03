# frozen_string_literal: true

class Settings::AuthorizedApplications::OauthApplicationPolicy < ApplicationPolicy
  def index?
    user.role_admin_for?(seller)
  end

  def create?
    index?
  end

  def edit?
    index?
  end

  def update?
    index?
  end

  def destroy?
    index?
  end
end
