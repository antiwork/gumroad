# frozen_string_literal: true

class AddLinkIdIndexToBaseVariants < ActiveRecord::Migration[4.2]
  def change
    add_index :base_variants, :link_id
  end
end
