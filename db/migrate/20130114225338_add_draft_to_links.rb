# frozen_string_literal: true

class AddDraftToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :draft, :boolean, default: false
  end
end
