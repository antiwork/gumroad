# frozen_string_literal: true

module Product::StaffPicked
  extend ActiveSupport::Concern

  def staff_picked?
    return false if staff_picked_product.blank?

    staff_picked_product.not_deleted?
  end

  def staff_picked_at
    return if staff_picked_product.blank? || staff_picked_product.deleted?

    staff_picked_product.updated_at
  end
end
