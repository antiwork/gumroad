# frozen_string_literal: true

class AddCustomPermalinkToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :custom_permalink, :string
  end
end
