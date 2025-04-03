# frozen_string_literal: true

class AddTotalFeeCentsToProductsIndex < ActiveRecord::Migration[6.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          total_fee_cents: { type: "long" }
        }
      }
    )
  end
end
