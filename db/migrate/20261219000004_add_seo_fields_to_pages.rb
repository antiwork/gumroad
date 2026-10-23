# frozen_string_literal: true

class AddSeoFieldsToPages < ActiveRecord::Migration[8.1]
  # Renumbered from 20261219000003, which main also took. A preview database
  # that ran the old number already has the columns.
  def up
    return if column_exists?(:pages, :seo_title)

    change_table :pages, bulk: true do |t|
      t.string :seo_title
      t.text :seo_description
    end
  end

  def down
    change_table :pages, bulk: true do |t|
      t.remove :seo_title, :seo_description
    end
  end
end
