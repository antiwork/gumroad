# frozen_string_literal: true

class AddDatesToVariants < ActiveRecord::Migration[4.2]
  def change
    add_column(:variants, :created_at, :datetime)
    add_column(:variants, :updated_at, :datetime)
  end
end
