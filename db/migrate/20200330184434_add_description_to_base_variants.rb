# frozen_string_literal: true

class AddDescriptionToBaseVariants < ActiveRecord::Migration
  def up
    add_column :base_variants, :description, :string, limit: 255
  end

  def down
    remove_column :base_variants, :description
  end
end
