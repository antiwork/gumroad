# frozen_string_literal: true

class AddDraftToLinks < ActiveRecord::Migration
  def change
    add_column :links, :draft, :boolean, default: false
  end
end
