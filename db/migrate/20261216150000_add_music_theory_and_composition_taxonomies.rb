# frozen_string_literal: true

# Adds Music Theory and Composition under Music & Sound Design.
#
# Deploys also run taxonomy:seed, which loads the same seed rows. This migration lands them as soon
# as db:migrate finishes, so they exist even if that non-fatal seed step fails (gumroad-private#3320).
class AddMusicTheoryAndCompositionTaxonomies < ActiveRecord::Migration[7.1]
  PARENT_SLUG = "music-and-sound-design"
  SLUGS = %w[music-theory composition].freeze

  def up
    # find_by_path, not find_by(slug:): slugs are unique per parent, not globally.
    parent = Taxonomy.find_by_path([PARENT_SLUG])

    if parent.nil?
      message = "Taxonomy #{PARENT_SLUG.inspect} was not found"
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
    # taxonomies_for_nav caches for an hour; without this the nav and the picker disagree until it expires.
    def bust_taxonomy_cache
      Rails.cache.delete("taxonomies_for_nav")
    end
end
