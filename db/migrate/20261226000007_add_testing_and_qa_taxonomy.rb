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

  # Only removes rows no product points at. A seller who categorised a product here between deploy
  # and rollback would otherwise lose that categorisation, which is worse than leaving a row behind.
  def down
    category = Taxonomy.find_by_path([PARENT_SLUG, CATEGORY_SLUG])
    return if category.nil?

    children = Taxonomy.where(parent: category).to_a
    in_use = Link.where(taxonomy_id: children.map(&:id) << category.id).distinct.pluck(:taxonomy_id)

    removable = children.reject { |child| in_use.include?(child.id) }
    # The parent goes only once nothing is left under it. Dropping it while a kept child still hangs
    # off it would orphan that child, putting the seller's product on a taxonomy path that no longer
    # resolves to a root — worse than the rollback simply leaving the subtree in place.
    keep_category = in_use.include?(category.id) || removable.size < children.size

    if keep_category
      say "Keeping the testing-and-qa category and #{children.size - removable.size} subcategory(ies) still referenced by products"
    end

    # destroy, not delete_all: closure_tree maintains taxonomy_hierarchies through callbacks, and a
    # bare delete would strand those rows, leaving self_and_ancestors wrong for the subtree.
    # Children first, so the parent is childless by the time it goes.
    removable.each(&:destroy!)
    category.destroy! unless keep_category
    bust_taxonomy_cache
  end

  private
    # taxonomies_for_nav caches for an hour, so without this the new category is invisible for up to
    # an hour after the migration runs, and the picker and nav disagree in the meantime.
    def bust_taxonomy_cache
      Rails.cache.delete("taxonomies_for_nav")
    end
end
