# frozen_string_literal: true

class AddCompoundIndexOnEmailInfos < ActiveRecord::Migration[7.0]
  def change
    change_table :email_infos, bulk: true do |t|
      t.index [:installment_id, :purchase_id]
      t.remove_index :installment_id
    end
  end
end
