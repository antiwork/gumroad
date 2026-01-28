# frozen_string_literal: true

class AddTaxonomyIdToPurchaseIndex < ActiveRecord::Migration[4.2]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          taxonomy_id: { type: "long" }
        }
      }
    )
  end
end
