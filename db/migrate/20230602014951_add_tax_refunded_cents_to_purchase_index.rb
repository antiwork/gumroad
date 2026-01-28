# frozen_string_literal: true

class AddTaxRefundedCentsToPurchaseIndex < ActiveRecord::Migration[4.2]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          tax_refunded_cents: { type: "long" }
        }
      }
    )
  end
end
