# frozen_string_literal: true

class MakeUrlRedirectsTokenUnique < ActiveRecord::Migration[7.0]
  def up
    change_table :url_redirects, bulk: true do |t|
      t.change :token, :string, null: false
      t.remove_index :token
      t.index :token, unique: true
    end
  end

  def down
    change_table :url_redirects, bulk: true do |t|
      t.change :token, :string, null: nil
      t.remove_index :token
      t.index :token
    end
  end
end
