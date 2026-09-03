# frozen_string_literal: true

class AddEmailIndexToAudienceMembers < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # Every other index here is seller_id-prefixed, so a lookup by email alone
    # scans the table — and under MIXED binlog the replica re-runs that scan.
    # 191 matches index_purchases_on_email_long: the utf8mb4 767-byte prefix.
    #
    # if_not_exists so the pt-osc copy can be run out of band — on a table this
    # size it cannot ride a deploy (gumroad-private#1810).
    add_index :audience_members, :email, name: "idx_audience_on_email", length: 191, if_not_exists: true
  end
end
