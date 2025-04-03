# frozen_string_literal: true

class AddPreorderIdToUrlRedirect < ActiveRecord::Migration
  def change
    add_column :url_redirects, :preorder_id, :integer
    add_index :url_redirects, :preorder_id
  end
end
