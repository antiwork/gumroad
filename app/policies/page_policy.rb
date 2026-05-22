# frozen_string_literal: true

class PagePolicy < ApplicationPolicy
  def index?
    admin_or_marketing?
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
    admin_or_marketing?
  end

  def destroy?
    update?
  end

  private
    def admin_or_marketing?
      user.role_admin_for?(seller) || user.role_marketing_for?(seller)
    rescue ActiveRecord::RecordNotFound
      false
    end
end
