# frozen_string_literal: true

class AddFlagsToBaseVariants < ActiveRecord::Migration[4.2]
  def change
    add_column :base_variants, :flags, :integer, default: 0, null: false
  end
end
