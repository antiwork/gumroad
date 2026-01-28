# frozen_string_literal: true

class AddExternalCssUrlToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :external_css_url, :string
  end
end
