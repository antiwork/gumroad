# frozen_string_literal: true

class AddSeoFieldsToPages < ActiveRecord::Migration[8.1]
  def change
    change_table :pages, bulk: true do |t|
      t.string :seo_title
      t.text :seo_description
    end
  end
end
