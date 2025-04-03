# frozen_string_literal: true

class AddRatedAsAdultToProductsIndex < ActiveRecord::Migration[6.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          rated_as_adult: { type: "boolean" }
        }
      }
    )
  end
end
