# frozen_string_literal: true

class Admin::Products::StaffPicked::LinkPolicy < ApplicationPolicy
  def create?
    return false if record.staff_picked_product&.not_deleted?

    record.recommendable?
  end

  def destroy?
    record.staff_picked_product&.not_deleted? || false
  end
end
