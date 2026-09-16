# frozen_string_literal: true

class Marketing::ActionPolicy < ApplicationPolicy
  def index?
    user.role_admin_for?(seller) || user.role_marketing_for?(seller)
  end

  def show?
    index? && record.user == seller
  end

  def approve? = show?
  def execute? = show?
  def cancel? = show?
end
