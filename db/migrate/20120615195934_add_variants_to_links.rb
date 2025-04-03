# frozen_string_literal: true

class AddVariantsToLinks < ActiveRecord::Migration
  def change
    add_column :links, :variants, :text
  end
end
