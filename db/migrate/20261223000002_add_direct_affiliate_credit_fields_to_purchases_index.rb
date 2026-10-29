# frozen_string_literal: true

class AddDirectAffiliateCreditFieldsToPurchasesIndex < ActiveRecord::Migration[8.1]
  def up
    # A branch preview builds its ES index at boot from Purchase::Searchable's
    # mapping, which already declares these four fields, and the shared staging
    # cluster sits at a 1000-shard cap, so the index legitimately may not exist
    # (config/initializers/prefix_for_branch_apps_es_index.rb logs that and lets
    # the app serve with empty search). put_mapping on a missing index raises a
    # 404 and would abort the entire preview deploy, so only map an index that is
    # actually there.
    return unless EsClient.indices.exists?(index: Purchase.index_name)

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
