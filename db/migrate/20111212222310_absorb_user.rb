# frozen_string_literal: true

class AbsorbUser < ActiveRecord::Migration
  def up
    add_column :users, :absorbed_to_user_id, :integer
    add_column :users, :deleted_at, :datetime
  end

  def down
    remove_column :users, :absorbed_to_user_id, :integer
    remove_column :users, :deleted_at, :datetime
  end
end
