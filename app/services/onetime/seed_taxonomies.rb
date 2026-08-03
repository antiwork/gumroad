# frozen_string_literal: true

# Applies the taxonomy tree to whatever environment it runs in.
#
# db/seeds.rb loads a seed subdirectory only when its underscore-delimited name contains the
# current Rails.env, and the tree lives in 010_development_staging_test/ — so rows added to the
# seed file reach every environment except the one sellers actually browse. #5764's six categories
# were still missing from production three weeks after shipping, with no error and no failing check.
#
# This loads the seed file rather than restating the tree, so there is no second copy to drift.
module Onetime
  class SeedTaxonomies
    SEED_PATH = "db/seeds/010_development_staging_test/taxonomy_create.rb"

    def self.process
      new.process
    end

    # Returns the number of taxonomies created. Safe to run on every deploy: every call in the
    # seed file is an idempotent find_or_create_by!, so a no-op run costs a few hundred SELECTs.
    def process
      # The seed file top-level-returns on this flag, so leaving it set anywhere the deploy can
      # see it would make this report success having done nothing — the failure it exists to end.
      raise "SKIP_TAXONOMY_CREATION is set; refusing to report success without seeding" if ENV["SKIP_TAXONOMY_CREATION"] == "1"

      before = Taxonomy.count
      load(Rails.root.join(SEED_PATH).to_s, true)
      created = Taxonomy.count - before

      # taxonomies_for_nav caches for an hour, so without this a new category is invisible for up
      # to an hour and the Discover nav and the product editor picker disagree in the meantime.
      Rails.cache.delete("taxonomies_for_nav")

      created
    end
  end
end
