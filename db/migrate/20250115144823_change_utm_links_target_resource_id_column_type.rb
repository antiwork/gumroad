# frozen_string_literal: true

class ChangeUtmLinksTargetResourceIdColumnType < ActiveRecord::Migration[4.2]
  def up
    change_column :utm_links, :target_resource_id, :bigint
  end

  def down
    change_column :utm_links, :target_resource_id, :string
  end
end
