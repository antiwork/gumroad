class CreateDiscountCollections < ActiveRecord::Migration[7.1]
  def change
    create_table :discount_collections do |t|
      t.string :name
      t.references :user, null: false, foreign_key: true
      t.text :description
      t.string :external_id
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
