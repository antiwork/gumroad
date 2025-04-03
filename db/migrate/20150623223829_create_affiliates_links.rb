# frozen_string_literal: true

class CreateAffiliatesLinks < ActiveRecord::Migration
  def change
    create_table :affiliates_links do |t|
      t.references :affiliate
      t.references :link

      t.timestamps
    end

    add_index :affiliates_links, :affiliate_id
    add_index :affiliates_links, :link_id
  end
end
