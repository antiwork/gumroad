# frozen_string_literal: true

class AddTaxAndFeeToPurchaseIndex < ActiveRecord::Migration[6.0]
  def up
    Elasticsearch::Model.client.indices.put_mapping(
      index: "purchases_v2",
      type: "purchase",
      body: {
        purchase: {
          properties: {
            fee_cents: { type: "long" },
            tax_cents: { type: "long" }
          }
        }
      }
    )
  end
end
