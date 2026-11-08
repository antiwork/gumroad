# frozen_string_literal: true

class CreatePurchaseRefundRequests < ActiveRecord::Migration[7.1]
  def change
    # New table only — nothing here touches the purchases table, so there is no
    # blocking DDL on it.
    create_table :purchase_refund_requests, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint :purchase_id, null: false
      t.string :email, null: false
      t.string :reason, null: false
      t.text :message
      t.string :state, null: false, default: "requested"
      # MySQL has no partial indexes, so "one OPEN request per purchase" is
      # expressed with a nullable key column: it holds purchase_id while the
      # request is open and NULL once it closes. NULLs never collide in a MySQL
      # unique index, so closed requests can accumulate while a second open one
      # is refused at the database.
      t.bigint :open_key

      t.timestamps

      t.index :purchase_id
      t.index :open_key, unique: true, name: "index_purchase_refund_requests_one_open_per_purchase"
    end
  end
end
