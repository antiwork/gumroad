# frozen_string_literal: true

class CreateUrlRedirects < ActiveRecord::Migration
  def change
    create_table :url_redirects do |t|
      t.integer :uses
      t.integer :link_id
      t.datetime :expires_at

      t.timestamps
    end
  end
end
