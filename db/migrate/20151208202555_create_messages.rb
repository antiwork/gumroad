# frozen_string_literal: true

class CreateMessages < ActiveRecord::Migration
  def change
    create_table :messages, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.belongs_to :parent
      t.belongs_to :purchase
      t.integer    :flags, default: 0, null: false
      t.string     :state
      t.text       :text
      t.string     :title
      t.datetime   :read_at
      t.datetime   :responded_at
      t.datetime   :deleted_at
      t.timestamps
    end
    add_index(:messages, :parent_id)
    add_index(:messages, :purchase_id)
  end
end
