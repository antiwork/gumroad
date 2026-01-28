# frozen_string_literal: true

class AddShownOnProfileToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :shown_on_profile, :boolean, default: true
  end
end
