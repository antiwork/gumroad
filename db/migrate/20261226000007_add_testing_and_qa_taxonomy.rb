# frozen_string_literal: true

# Creates the Testing & QA category and its subcategories in every environment.
#
# The taxonomy tree is defined in db/seeds/010_development_staging_test/taxonomy_create.rb, and
# deploys also run taxonomy:seed, which loads those rows. This migration lands them as soon as
# db:migrate finishes, so they exist even if that non-fatal seed step fails (gumroad-private#3320).
# Follows #6870, #8231 and #8842.
class AddTestingAndQaTaxonomy < ActiveRecord::Migration[7.1]
  PARENT_SLUG = "software-development"
  CATEGORY_SLUG = "testing-and-qa"
  SUBCATEGORY_SLUGS = %w[
    test-automation
    manual-testing
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

    # Created through the model so closure_tree records the taxonomy_hierarchies rows.
    category = Taxonomy.find_or_create_by!(slug: CATEGORY_SLUG, parent:)
    SUBCATEGORY_SLUGS.each do |slug|
      Taxonomy.find_or_create_by!(slug:, parent: category)
    end

    bust_taxonomy_cache
  end

  # Irreversible on purpose: a rollback that deletes a category can race a seller saving a product
  # under it and leave a dangling taxonomy_id. The additive rows are harmless to keep.
  def down
    say "Keeping #{[CATEGORY_SLUG, *SUBCATEGORY_SLUGS].join(", ")}: removing a category could orphan products saved under it"
  end

  private
    # taxonomies_for_nav caches for an hour, so without this the new category is invisible for up to
    # an hour after the migration runs, and the picker and nav disagree in the meantime.
    def bust_taxonomy_cache
      Rails.cache.delete("taxonomies_for_nav")
    end
end
