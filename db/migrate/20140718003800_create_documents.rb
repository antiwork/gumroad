# frozen_string_literal: true

class CreateDocuments < ActiveRecord::Migration
  def change
    create_table :documents do |t|
      t.belongs_to  :product_file
      t.string      :state
      t.string      :external_docspad_id
      t.timestamps
    end
    add_index :documents, :external_docspad_id
  end
end
