# frozen_string_literal: true

class AddDirectAffiliateCreditAffiliateUserIdToPurchasesIndex < ActiveRecord::Migration[8.1]
  def up
    # Same shape as the sibling put_mapping migration: a branch preview builds its ES index at boot
    # from Purchase::Searchable's mapping and the shared staging cluster sits at a shard cap, so the
    # index may legitimately not exist and put_mapping would abort the deploy.
    return unless EsClient.indices.exists?(index: Purchase.index_name)

    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          direct_affiliate_credit_affiliate_user_id: { type: "long" },
        }
      }
    )
  end

  def down
  end
end
