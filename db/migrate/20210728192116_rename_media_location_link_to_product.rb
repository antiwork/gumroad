# frozen_string_literal: true

class RenameMediaLocationLinkToProduct < ActiveRecord::Migration[6.1]
  def up
    Alterity.disable do
      rename_column :media_locations, :link_id, :product_id
    end
  end

  def down
    Alterity.disable do
      rename_column :media_locations, :product_id, :link_id
    end
  end
end
