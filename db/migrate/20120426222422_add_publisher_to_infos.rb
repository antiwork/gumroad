# frozen_string_literal: true

class AddPublisherToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :publisher, :string
  end
end
