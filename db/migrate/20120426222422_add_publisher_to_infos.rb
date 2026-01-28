# frozen_string_literal: true

class AddPublisherToInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :infos, :publisher, :string
  end
end
