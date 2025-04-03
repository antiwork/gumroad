# frozen_string_literal: true

class AddRefunderToRefunds < ActiveRecord::Migration
  def up
    add_column :refunds, :refunding_user_id, :integer
  end

  def down
    remove_column :refunds, :refunding_user_id
  end
end
