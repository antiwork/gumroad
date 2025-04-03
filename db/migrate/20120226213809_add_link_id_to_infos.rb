# frozen_string_literal: true

class AddLinkIdToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :link_id, :integer
  end
end
