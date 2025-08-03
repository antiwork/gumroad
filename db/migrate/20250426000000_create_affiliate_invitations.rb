# frozen_string_literal: true

class CreateAffiliateInvitations < ActiveRecord::Migration[7.1]
  def change
    create_table :affiliate_invitations do |t|
      t.integer :affiliate_id, null: false, index: { unique: true }

      t.timestamps
    end

    add_foreign_key :affiliate_invitations, :affiliates, on_delete: :cascade
  end
end
