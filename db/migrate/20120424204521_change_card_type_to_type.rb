# frozen_string_literal: true

class ChangeCardTypeToType < ActiveRecord::Migration
  def up
    rename_column :credit_cards, :card_type, :type
  end

  def down
    rename_column :credit_cards, :type, :card_type
  end
end
