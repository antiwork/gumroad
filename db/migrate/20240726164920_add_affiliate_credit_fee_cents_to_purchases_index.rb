# frozen_string_literal: true

class AddAffiliateCreditFeeCentsToPurchasesIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          affiliate_credit_fee_cents: { type: "long" },
        }
      }
    )
  end
end
