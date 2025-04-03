# frozen_string_literal: true

class DropBins < ActiveRecord::Migration[7.0]
  def up
    drop_table :bins
  end

  def down
    create_table "bins", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.string "card_bin"
      t.string "issuing_bank"
      t.string "card_type"
      t.string "card_level"
      t.string "iso_country_name"
      t.string "iso_country_a2"
      t.string "iso_country_a3"
      t.integer "iso_country_number"
      t.string "website"
      t.string "phone_number"
      t.string "card_brand"
      t.index ["card_bin"], name: "index_bins_on_card_bin"
    end
  end
end
