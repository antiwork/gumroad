# frozen_string_literal: true

class RemoveBalanceCentsFromLinks < ActiveRecord::Migration[4.2]
  def up
    remove_column :links, :balance_cents
  end

  def down
    add_column :links, :balance_cents, :integer
  end
end
