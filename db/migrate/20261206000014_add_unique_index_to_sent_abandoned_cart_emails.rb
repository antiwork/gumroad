# frozen_string_literal: true

class AddUniqueIndexToSentAbandonedCartEmails < ActiveRecord::Migration[7.1]
  def change
    # The duplicate-send guard for abandoned-cart emails: every reader of this table
    # (Cart.abandoned, Cart#abandoned?, CustomerMailer#abandoned_cart) is check-then-write,
    # so two concurrent scheduler or mailer runs could each email the same cart
    # (gumroad-private#1576). CustomerMailer already rescues RecordNotUnique on this
    # insert — this index is what makes that rescue actually fire. The table was verified
    # duplicate-free in production, so the index builds directly.
    change_table :sent_abandoned_cart_emails, bulk: true do |t|
      t.index [:cart_id, :installment_id], unique: true
      # Redundant leftmost prefix of the unique index above.
      t.remove_index [:cart_id]
    end
  end
end
