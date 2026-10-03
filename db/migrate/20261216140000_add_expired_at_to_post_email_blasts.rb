# frozen_string_literal: true

class AddExpiredAtToPostEmailBlasts < ActiveRecord::Migration[7.1]
  def change
    change_table :post_email_blasts, bulk: true do |t|
      t.datetime :expired_at
      t.string :expiry_reason
    end
  end
end
