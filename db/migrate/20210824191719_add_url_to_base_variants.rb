# frozen_string_literal: true

class AddUrlToBaseVariants < ActiveRecord::Migration[4.2]
  def change
    add_column :base_variants, :url, :string
  end
end
