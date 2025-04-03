# frozen_string_literal: true

class AddChargeProcessorIdToCreditCard < ActiveRecord::Migration
  def up
    add_column :credit_cards, :charge_processor_id, :string
    CreditCard.update_all({ charge_processor_id: "stripe" })
  end

  def down
    remove_column :credit_cards, :charge_processor_id
  end
end
