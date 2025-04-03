# frozen_string_literal: true

class RemoveLinksVariants < ActiveRecord::Migration[6.1]
  def up
    remove_column :links, :variants
  end

  def down
    add_column :links, :variants, :text, size: :medium
  end
end
