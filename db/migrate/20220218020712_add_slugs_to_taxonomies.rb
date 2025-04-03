# frozen_string_literal: true

class AddSlugsToTaxonomies < ActiveRecord::Migration[6.1]
  def change
    add_column :taxonomies, :slug, :string
  end
end
