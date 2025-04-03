# frozen_string_literal: true

# Library section
#
class PurchasePolicy < ApplicationPolicy
  def index?
    user.role_owner_for?(seller)
  end

  def archive?
    index?
  end

  def unarchive?
    index?
  end

  def delete?
    index?
  end
end
