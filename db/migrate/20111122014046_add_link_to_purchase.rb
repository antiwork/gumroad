# frozen_string_literal: true

class AddLinkToPurchase < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :link_id, :integer
  end
end
