# frozen_string_literal: true

class AddAffiliateCreditFeePartiallyRefundedCentsToPurchasesIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          affiliate_credit_fee_partially_refunded_cents: { type: "long" },
        }
      }
    )
  end
end
