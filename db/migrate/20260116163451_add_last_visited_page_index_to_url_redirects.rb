# frozen_string_literal: true

class AddLastVisitedPageIndexToUrlRedirects < ActiveRecord::Migration[7.1]
  def change
    add_column :url_redirects, :last_visited_page_id, :string
  end
end
