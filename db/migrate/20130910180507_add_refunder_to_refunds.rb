# frozen_string_literal: true

class AddRefunderToRefunds < ActiveRecord::Migration[4.2]
  def up
    add_column :refunds, :refunding_user_id, :integer
  end

  def down
    remove_column :refunds, :refunding_user_id
  end
end
