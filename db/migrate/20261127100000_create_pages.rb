# frozen_string_literal: true

class CreatePages < ActiveRecord::Migration[7.1]
  def change
    create_table :pages do |t|
      t.references :pageable, polymorphic: true, null: false, index: { unique: true, name: "index_pages_on_pageable" }
      t.longtext :custom_html
      t.timestamps
    end
  end
end
