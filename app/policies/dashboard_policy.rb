# frozen_string_literal: true

class DashboardPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def customers_count? = index?
  def total_revenue? = index?
  def active_members_count? = index?
  def monthly_recurring_revenue? = index?
  def download_tax_form? = index?
end
