# frozen_string_literal: true

class AddIdToFollows < ActiveRecord::Migration
  def change
    add_column :follows, :id, :primary_key
  end
end
