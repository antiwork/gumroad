# frozen_string_literal: true

class AddCustomPermalinkToLinks < ActiveRecord::Migration
  def change
    add_column :links, :custom_permalink, :string
  end
end
