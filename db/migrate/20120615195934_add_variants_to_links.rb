# frozen_string_literal: true

class AddVariantsToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :variants, :text
  end
end
