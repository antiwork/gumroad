# frozen_string_literal: true

class AddNullFalseToTaxonomiesSlug < ActiveRecord::Migration[6.1]
  def up
    if Rails.env.development? && Taxonomy.where(slug: nil).exists?
      raise <<~ERROR
        Your database contains a Taxonomy without slug.

        To fix it, run the script to fill the taxonomy slugs
          Onetime::FillTaxonomySlugs.process

        or re-seed taxonomies in your db
          Taxonomy.destroy_all && load 'db/seeds/000_development_staging/taxonomy.rb'

        before running this migration.
      ERROR
    end

    change_column_null :taxonomies, :slug, false
    change_column_null :taxonomies, :name, true
  end

  def down
    change_column_null :taxonomies, :slug, true
    change_column_null :taxonomies, :name, false
  end
end
