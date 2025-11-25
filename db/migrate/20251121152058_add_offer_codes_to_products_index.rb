# frozen_string_literal: true

class AddOfferCodesToProductsIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          offer_codes: {
            type: "text",
            fields: {
              code: {
                type: "keyword",
                ignore_above: 256
              }
            }
          }
        }
      }
    )
  end
end
