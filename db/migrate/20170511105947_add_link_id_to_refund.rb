# frozen_string_literal: true

class AddLinkIdToRefund < ActiveRecord::Migration
  def change
    add_column :refunds, :link_id, :integer
    add_index :refunds, :link_id
  end
end
