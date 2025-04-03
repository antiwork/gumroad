# frozen_string_literal: true

class AddIsCallAndIsAliveToProductsIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          is_call: { type: "boolean" },
          is_alive: { type: "boolean" },
        }
      }
    )
  end
end
