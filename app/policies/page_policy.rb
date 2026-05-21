# frozen_string_literal: true

class PagePolicy < ApplicationPolicy
  def index?
    user.role_admin_for?(seller) || user.role_marketing_for?(seller)
  end

  def templates?
    index?
  end

  def new?
    index?
  end

  def create?
    new?
  end

  def edit?
    update?
  end

  def latest_version?
    edit?
  end

  def update?
    user.role_admin_for?(seller) || user.role_marketing_for?(seller)
  end

  def destroy?
    update?
  end
end
