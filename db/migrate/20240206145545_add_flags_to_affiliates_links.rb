# frozen_string_literal: true

class AddFlagsToAffiliatesLinks < ActiveRecord::Migration[7.0]
  def change
    add_column :affiliates_links, :flags, :bigint, default: 0, null: false
  end
end
