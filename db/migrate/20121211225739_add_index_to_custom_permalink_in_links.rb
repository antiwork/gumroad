# frozen_string_literal: true

class AddIndexToCustomPermalinkInLinks < ActiveRecord::Migration[4.2]
  def change
    add_index :links, :custom_permalink
  end
end
