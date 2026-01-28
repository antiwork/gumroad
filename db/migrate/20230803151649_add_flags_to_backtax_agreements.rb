# frozen_string_literal: true

class AddFlagsToBacktaxAgreements < ActiveRecord::Migration[4.2]
  def change
    add_column :backtax_agreements, :flags, :bigint, default: 0, null: false
  end
end
