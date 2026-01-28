# frozen_string_literal: true

class ChangeCvcCheckToCvcCheckFailed < ActiveRecord::Migration[4.2]
  def up
    rename_column(:credit_cards, :cvc_check, :cvc_check_failed)
  end

  def down
    rename_column(:credit_cards, :cvc_check_failed, :cvc_check)
  end
end
