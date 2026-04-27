# frozen_string_literal: true

class Settings::BillingPolicy < ApplicationPolicy
  def show?
    user == seller
  end

  def update?
    show?
  end
end
