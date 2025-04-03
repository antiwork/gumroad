# frozen_string_literal: true

class AddLinkIdToUrlRedirects < ActiveRecord::Migration
  def change
    add_column :url_redirects, :link_id, :integer
  end
end
