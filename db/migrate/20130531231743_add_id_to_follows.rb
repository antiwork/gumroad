# frozen_string_literal: true

class AddIdToFollows < ActiveRecord::Migration[4.2]
  def change
    add_column :follows, :id, :primary_key
  end
end
