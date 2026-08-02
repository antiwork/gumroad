# frozen_string_literal: true

# Creates the Cybersecurity category and its subcategories in every environment.
#
# The taxonomy tree is defined in db/seeds/010_development_staging_test/taxonomy_create.rb, but
# db/seeds.rb only loads a seed subdirectory whose underscore-delimited name contains the current
# Rails.env, and production deploys run db:migrate rather than db:seed anyway
# (docker/web/database_migration.sh). So a category added to the seed file alone never reaches
# production: #5764 added six rows in July and none of them exist there today. The seed entries
# stay for fresh development and test databases; this migration is what lands the rows in
# production. The wider fix for the seed path is antiwork/gumroad-private#1738.
class AddCybersecurityTaxonomy < ActiveRecord::Migration[7.1]
  PARENT_SLUG = "software-development"
  CATEGORY_SLUG = "cybersecurity"
  SUBCATEGORY_SLUGS = %w[
    network-security
    penetration-testing
    security-and-compliance
    privacy-and-encryption
  ].freeze

  def up
    # find_by_path, not find_by(slug:): slugs are unique per parent, not globally (illustrator sits
    # under both print-and-packaging and mockups), so a bare slug lookup is ambiguous by design.
    parent = Taxonomy.find_by_path([PARENT_SLUG])

    if parent.nil?
      message = "Taxonomy #{PARENT_SLUG.inspect} was not found"
      raise ActiveRecord::RecordNotFound, message if Rails.env.production?

      say "#{message}; skipping (an unseeded database gets these rows from the seed file)"
      return
    end

    category = Taxonomy.find_or_create_by!(slug: CATEGORY_SLUG, parent:)
    SUBCATEGORY_SLUGS.each do |slug|
      Taxonomy.find_or_create_by!(slug:, parent: category)
    end

    bust_taxonomy_cache
  end

  # Only removes a subcategory that is empty. A seller who categorised a product here between
  # deploy and rollback would otherwise have it silently repointed by the foreign key, and losing
  # a seller's categorisation is worse than leaving a row behind.
  def down
    category = Taxonomy.find_by_path([PARENT_SLUG, CATEGORY_SLUG])
    return if category.nil?

    rows = Taxonomy.where(parent: category).to_a << category
    in_use = Link.where(taxonomy_id: rows.map(&:id)).distinct.pluck(:taxonomy_id)

    if in_use.any?
      say "Keeping #{in_use.size} cybersecurity taxonomy row(s) still referenced by products"
      rows.reject! { |row| in_use.include?(row.id) }
    end

    # destroy, not delete_all: closure_tree maintains taxonomy_hierarchies through callbacks, and
    # a bare delete would strand those rows, leaving self_and_ancestors wrong for the subtree.
    # Children first, so the parent is childless by the time it goes.
    rows.sort_by { |row| row.slug == CATEGORY_SLUG ? 1 : 0 }.each(&:destroy!)
    bust_taxonomy_cache
  end

  private
    # taxonomies_for_nav caches for an hour, so without this the new category is invisible for up
    # to an hour after the migration runs, and the picker and nav disagree in the meantime.
    def bust_taxonomy_cache
      Rails.cache.delete("taxonomies_for_nav")
    end
end
