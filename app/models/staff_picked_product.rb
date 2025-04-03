# frozen_string_literal: true

class StaffPickedProduct < ApplicationRecord
  include TimestampStateFields

  has_paper_trail

  belongs_to :product, class_name: "Link"

  validates :product, presence: true, uniqueness: true

  timestamp_state_fields :deleted

  after_commit :update_product_search_index

  private
    def update_product_search_index
      product.enqueue_index_update_for(["staff_picked_at"])
    end
end
