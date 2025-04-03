# frozen_string_literal: true

class AddAvailablePriceCentsToProductIndex < ActiveRecord::Migration[6.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          available_price_cents: { type: "long" },
        }
      }
    )
  end
end
