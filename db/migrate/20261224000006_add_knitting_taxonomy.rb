# frozen_string_literal: true

# Adds Knitting under Crafts & DIY.
#
# Deploys also run taxonomy:seed, which loads the same seed rows. This migration lands them as soon
# as db:migrate finishes, so they exist even if that non-fatal seed step fails (gumroad-private#3320).
class AddKnittingTaxonomy < ActiveRecord::Migration[7.1]
  # find_by_path walks down from a root, so Crafts & DIY has to be addressed by its full ancestor
  # path. A one-element path resolves to nil here and, in production, raises and fails the deploy.
  PARENT_PATH = %w[self-improvement crafts-and-dyi].freeze
  SLUGS = %w[knitting].freeze

  def up
    parent = Taxonomy.find_by_path(PARENT_PATH)

    if parent.nil?
      message = "Taxonomy #{PARENT_PATH.join("/").inspect} was not found"
      raise ActiveRecord::RecordNotFound, message if Rails.env.production?

      say "#{message}; skipping (an unseeded database gets these rows from the seed file)"
      return
    end

    # Created through the model so closure_tree records the taxonomy_hierarchies rows.
    SLUGS.each { |slug| Taxonomy.find_or_create_by!(slug:, parent:) }

    bust_taxonomy_cache
  end

  # Irreversible on purpose: a rollback that deletes a category can race a seller saving a product
  # under it and leave a dangling taxonomy_id. The additive rows are harmless to keep.
  def down
    say "Keeping #{SLUGS.join(", ")}: removing a category could orphan products saved under it"
  end

  private
    # taxonomies_for_nav caches for an hour and feeds both the nav and the picker; without this
    # neither shows the new category until it expires.
    def bust_taxonomy_cache
      Rails.cache.delete("taxonomies_for_nav")
    end
end
