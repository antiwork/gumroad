# frozen_string_literal: true

class Checkout::DiscountCollectionPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def create?
    user.present?
  end

  def update?
    record.user_id == user.id
  end

  def destroy?
    record.user_id == user.id
  end

  def bulk_create_codes?
    record.user_id == user.id
  end

  def show?
    record.user_id == user.id
  end
end
