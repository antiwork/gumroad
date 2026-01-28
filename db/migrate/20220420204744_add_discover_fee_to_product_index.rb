# frozen_string_literal: true

class AddDiscoverFeeToProductIndex < ActiveRecord::Migration[4.2]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          discover_fee_per_thousand: { type: "integer" }
        }
      }
    )
  end
end
