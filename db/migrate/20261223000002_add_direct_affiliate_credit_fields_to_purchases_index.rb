# frozen_string_literal: true

class AddDirectAffiliateCreditFieldsToPurchasesIndex < ActiveRecord::Migration[8.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          direct_affiliate_credit_amount_cents: { type: "long" },
          direct_affiliate_credit_fee_cents: { type: "long" },
          direct_affiliate_credit_amount_partially_refunded_cents: { type: "long" },
          direct_affiliate_credit_fee_partially_refunded_cents: { type: "long" },
        }
      }
    )
  end

  def down
  end
end
