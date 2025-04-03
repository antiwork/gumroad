# frozen_string_literal: true

class AddDeletedAtToVariants < ActiveRecord::Migration
  def change
    add_column :variants, :deleted_at, :datetime
  end
end
