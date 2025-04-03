# frozen_string_literal: true

class CreateBacktaxAgreements < ActiveRecord::Migration[7.0]
  def change
    create_table :backtax_agreements do |t|
      t.references :user, index: true, null: false

      t.string "jurisdiction"
      t.string "signature"

      t.timestamps
    end
  end
end
