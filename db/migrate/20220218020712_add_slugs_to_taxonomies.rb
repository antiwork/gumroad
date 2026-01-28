# frozen_string_literal: true

class AddSlugsToTaxonomies < ActiveRecord::Migration[4.2]
  def change
    add_column :taxonomies, :slug, :string
  end
end
