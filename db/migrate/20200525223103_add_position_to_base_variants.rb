# frozen_string_literal: true

class AddPositionToBaseVariants < ActiveRecord::Migration
  def change
    add_column :base_variants, :position_in_category, :integer
  end
end
