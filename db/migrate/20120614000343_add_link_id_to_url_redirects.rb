# frozen_string_literal: true

class AddLinkIdToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :link_id, :integer
  end
end
