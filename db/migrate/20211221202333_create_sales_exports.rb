# frozen_string_literal: true

class CreateSalesExports < ActiveRecord::Migration[6.1]
  def change
    create_table :sales_exports do |t|
      t.bigint :recipient_id, null: false, index: true
      t.text :query
      t.timestamps
    end
  end
end
