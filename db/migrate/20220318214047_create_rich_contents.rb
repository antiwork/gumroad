# frozen_string_literal: true

class CreateRichContents < ActiveRecord::Migration[6.1]
  def change
    create_table :rich_contents do |t|
      t.bigint :entity_id, null: false
      t.string :entity_type, null: false
      t.json :description, null: false

      t.timestamps
    end

    add_index :rich_contents, [:entity_id, :entity_type], unique: true
  end
end
