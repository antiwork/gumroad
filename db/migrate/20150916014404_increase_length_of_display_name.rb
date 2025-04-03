# frozen_string_literal: true

class IncreaseLengthOfDisplayName < ActiveRecord::Migration
  def change
    change_column(:product_files, :display_name, :string, limit: 1024)
  end
end
