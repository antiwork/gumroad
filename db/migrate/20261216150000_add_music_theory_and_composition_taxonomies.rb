# frozen_string_literal: true

# Adds Music Theory and Composition under Music & Sound Design in every environment.
#
# The seed file alone never reaches production: db/seeds.rb skips this seed directory there and
# deploys run db:migrate, not db:seed (antiwork/gumroad-private#1738, as in #6870). The seed entries
# stay for fresh development and test databases; this migration lands the rows in production.
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

  # Keeps any row a product already points at, so a rollback cannot drop a seller's categorisation.
  def down
    parent = Taxonomy.find_by_path([PARENT_SLUG])
    return if parent.nil?

    rows = Taxonomy.where(parent:, slug: SLUGS).to_a
    in_use = Link.where(taxonomy_id: rows.map(&:id)).distinct.pluck(:taxonomy_id)

    say "Keeping #{in_use.size} taxonomy row(s) still referenced by products" if in_use.any?

    rows.reject { |row| in_use.include?(row.id) }.each(&:destroy!)
    bust_taxonomy_cache
  end

  private
    # taxonomies_for_nav caches for an hour; without this the nav and the picker disagree until it expires.
    def bust_taxonomy_cache
      Rails.cache.delete("taxonomies_for_nav")
    end
end
