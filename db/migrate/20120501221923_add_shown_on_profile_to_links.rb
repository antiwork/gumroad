# frozen_string_literal: true

class AddShownOnProfileToLinks < ActiveRecord::Migration
  def change
    add_column :links, :shown_on_profile, :boolean, default: true
  end
end
