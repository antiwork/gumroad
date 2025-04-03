# frozen_string_literal: true

# This script updates products marked as `is_physical` with a `native_type` of "digital" to have a `native_type` of "physical"
#
# Steps:
# 1. In Rails console: Onetime::AssignPhysicalProductTypes.process
class Onetime::AssignPhysicalProductTypes
  def self.process
    invalid_products = Link.is_physical.where(native_type: Link::NATIVE_TYPE_DIGITAL)

    invalid_products.find_in_batches do |products|
      ReplicaLagWatcher.watch

      Link.where(id: products.map(&:id)).update_all(native_type: Link::NATIVE_TYPE_PHYSICAL)
    end
  end
end
