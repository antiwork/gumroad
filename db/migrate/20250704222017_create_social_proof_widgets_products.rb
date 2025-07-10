# frozen_string_literal: true

class CreateSocialProofWidgetsProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :social_proof_widgets_products do |t|
      t.references :social_proof_widget, null: false
      t.references :product, null: false

      t.timestamps
    end

    add_index :social_proof_widgets_products, :social_proof_widget_id, name: "index_spw_products_on_spw_id"
    add_index :social_proof_widgets_products, :product_id, name: "index_spw_products_on_product_id"
  end
end