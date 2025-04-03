# frozen_string_literal: true

class AddProductDescriptionToDisputeEvidences < ActiveRecord::Migration[7.0]
  def change
    add_column :dispute_evidences, :product_description, :text
  end
end
