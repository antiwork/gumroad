# frozen_string_literal: true

# The daily finance event-ledger report scans refunds by creation day. The only
# time-based index on refunds is (seller_id, created_at), which can't serve a
# seller-agnostic date-window query.
class AddCreatedAtIndexToRefunds < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :refunds, :created_at, name: "index_refunds_on_created_at"
  end
end
