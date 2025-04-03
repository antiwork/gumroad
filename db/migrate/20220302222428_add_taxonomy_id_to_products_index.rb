# frozen_string_literal: true

class AddTaxonomyIdToProductsIndex < ActiveRecord::Migration[6.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          taxonomy_id: { type: "long" },
        }
      }
    )
  end
end
