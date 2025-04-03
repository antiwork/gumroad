# frozen_string_literal: true

class AddIndexToCustomPermalinkInLinks < ActiveRecord::Migration
  def change
    add_index :links, :custom_permalink
  end
end
