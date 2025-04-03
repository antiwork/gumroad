# frozen_string_literal: true

class AddDurationInMinutesToBaseVariants < ActiveRecord::Migration[7.1]
  def change
    add_column :base_variants, :duration_in_minutes, :integer
  end
end
