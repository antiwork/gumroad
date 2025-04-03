# frozen_string_literal: true

class CreateProductEmbeddings < ActiveRecord::Migration[7.0]
  def change
    create_table :product_embeddings do |t|
      t.references :product, null: false, index: { unique: true }
      t.text :body, size: :medium
      t.json :vector
      t.timestamps
    end
  end
end
