# frozen_string_literal: true

class AddLinkIdToRefund < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :link_id, :integer
    add_index :refunds, :link_id
  end
end
