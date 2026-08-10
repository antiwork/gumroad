# frozen_string_literal: true

class AddProductNameRawToPurchasesIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          product_name: {
            type: "text",
            analyzer: "product_name",
            search_analyzer: "search_product_name",
            fields: { raw: { type: "keyword" } }
          },
        }
      }
    )
  end

  def down
  end
end
