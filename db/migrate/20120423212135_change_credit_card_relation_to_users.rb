# frozen_string_literal: true

class ChangeCreditCardRelationToUsers < ActiveRecord::Migration[4.2]
  def up
    remove_column :credit_cards, :user_id
    add_column :users, :credit_card_id, :integer
  end

  def down
    add_column :credit_cards, :user_id, :integer
    remove_column :users, :credit_card_id
  end
end
