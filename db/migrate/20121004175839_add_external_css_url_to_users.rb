# frozen_string_literal: true

class AddExternalCssUrlToUsers < ActiveRecord::Migration
  def change
    add_column :users, :external_css_url, :string
  end
end
