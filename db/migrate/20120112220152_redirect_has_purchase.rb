# frozen_string_literal: true

class RedirectHasPurchase < ActiveRecord::Migration
  def up
    add_column :url_redirects, :purchase_id, :integer
    remove_column :url_redirects, :link_id
  end

  def down
    remove_column :url_redirects, :purchase_id
    add_column :url_redirects, :link_id, :integer
  end
end
