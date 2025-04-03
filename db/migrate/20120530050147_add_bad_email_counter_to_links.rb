# frozen_string_literal: true

class AddBadEmailCounterToLinks < ActiveRecord::Migration
  def change
    add_column :links, :bad_email_counter, :integer, default: 0
  end
end
