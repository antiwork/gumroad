# frozen_string_literal: true

class AddDemoSelectedAtToProductBuilds < ActiveRecord::Migration[8.1]
  def change
    add_column :product_builds, :demo_selected_at, :datetime
  end
end
