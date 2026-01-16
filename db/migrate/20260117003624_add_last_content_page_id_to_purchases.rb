# frozen_string_literal: true

class AddLastContentPageIdToPurchases < ActiveRecord::Migration[7.1]
  def change
    add_column :purchases, :last_content_page_id, :string
    add_column :purchases, :last_content_page_viewed_at, :datetime
  end
end

