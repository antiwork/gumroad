# frozen_string_literal: true

class AddDatesToVariants < ActiveRecord::Migration
  def change
    add_column(:variants, :created_at, :datetime)
    add_column(:variants, :updated_at, :datetime)
  end
end
