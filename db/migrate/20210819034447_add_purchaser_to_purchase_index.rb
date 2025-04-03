# frozen_string_literal: true

class AddPurchaserToPurchaseIndex < ActiveRecord::Migration[6.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          purchaser: {
            type: :nested,
            properties: {
              id: { type: :long }
            }
          }
        }
      }
    )
  end
end
