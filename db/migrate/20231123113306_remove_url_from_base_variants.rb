# frozen_string_literal: true

class RemoveUrlFromBaseVariants < ActiveRecord::Migration[4.2]
  def up
    remove_column :base_variants, :url
  end

  def down
    add_column :base_variants, :url, :string
  end
end
