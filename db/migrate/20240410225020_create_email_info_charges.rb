# frozen_string_literal: true

class CreateEmailInfoCharges < ActiveRecord::Migration[7.0]
  def change
    create_table :email_info_charges do |t|
      t.references :email_info, index: true, null: false
      t.references :charge, index: true, null: false
    end
  end
end
