# frozen_string_literal: true

class AddEmailIndexToAudienceMembers < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # Every other index on this table is seller_id-prefixed, so looking a buyer up
    # by email alone has no usable index and scans the table. Under MIXED binlog
    # format the replica re-executes that scan, so it costs replica lag as well as
    # primary time. 191 is the utf8mb4 prefix that fits the 767-byte key limit,
    # matching index_purchases_on_email_long.
    add_index :audience_members, :email, name: "idx_audience_on_email", length: 191
  end
end
