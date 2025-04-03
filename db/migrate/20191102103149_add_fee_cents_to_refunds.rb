# frozen_string_literal: true

class AddFeeCentsToRefunds < ActiveRecord::Migration
  def up
    add_column :refunds, :fee_cents, :integer
  end

  def down
    remove_column :refunds, :fee_cents
  end
end
