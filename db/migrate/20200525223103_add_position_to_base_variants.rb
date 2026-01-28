# frozen_string_literal: true

class AddPositionToBaseVariants < ActiveRecord::Migration[4.2]
  def change
    add_column :base_variants, :position_in_category, :integer
  end
end
