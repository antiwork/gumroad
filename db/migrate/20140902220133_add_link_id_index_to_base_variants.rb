# frozen_string_literal: true

class AddLinkIdIndexToBaseVariants < ActiveRecord::Migration
  def change
    add_index :base_variants, :link_id
  end
end
