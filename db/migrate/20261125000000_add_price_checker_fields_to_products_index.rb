# frozen_string_literal: true

class AddPriceCheckerFieldsToProductsIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          price_currency_type: { type: "keyword" },
          customizable_price: { type: "boolean" },
          native_type: { type: "keyword" },
        }
      }
    )
  end
end
