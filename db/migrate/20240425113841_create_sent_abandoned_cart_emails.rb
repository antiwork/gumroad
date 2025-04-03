# frozen_string_literal: true

class CreateSentAbandonedCartEmails < ActiveRecord::Migration[7.1]
  def change
    create_table :sent_abandoned_cart_emails do |t|
      t.references :cart, null: false
      t.references :installment, null: false
      t.timestamps
    end
  end
end
