# frozen_string_literal: true

class AddDeletedAtToVariants < ActiveRecord::Migration[4.2]
  def change
    add_column :variants, :deleted_at, :datetime
  end
end
