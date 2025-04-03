# frozen_string_literal: true

class AddStaffPickedAtToProductsIndex < ActiveRecord::Migration[7.0]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          staff_picked_at: { type: "date" }
        }
      }
    )
  end
end
