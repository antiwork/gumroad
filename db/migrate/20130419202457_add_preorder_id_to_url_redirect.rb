# frozen_string_literal: true

class AddPreorderIdToUrlRedirect < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :preorder_id, :integer
    add_index :url_redirects, :preorder_id
  end
end
