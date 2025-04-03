# frozen_string_literal: true

class AddUrlToBaseVariants < ActiveRecord::Migration[6.1]
  def change
    add_column :base_variants, :url, :string
  end
end
