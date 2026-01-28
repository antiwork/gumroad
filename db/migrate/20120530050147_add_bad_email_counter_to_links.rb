# frozen_string_literal: true

class AddBadEmailCounterToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :bad_email_counter, :integer, default: 0
  end
end
