# frozen_string_literal: true

class AddIsBundleToProductsIndex < ActiveRecord::Migration[4.2]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          is_bundle: { type: "boolean" }
        }
      }
    )
  end
end
