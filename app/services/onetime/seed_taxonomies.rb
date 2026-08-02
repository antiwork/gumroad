# frozen_string_literal: true

# Applies the taxonomy seed to an environment the seed loader will not reach on its own.
#
# db/seeds.rb only loads a subdirectory when its underscore-delimited name contains the current
# Rails.env, and the taxonomy rows live in db/seeds/010_development_staging_test/. Production is
# not in that list, so shipping a new category in the seed file does nothing there — PR #5764
# added six rows in July and none of them exist in production today.
#
# Run from a console after the deploy:
#
#   Onetime::SeedTaxonomies.new.process                 # report what is missing
#   Onetime::SeedTaxonomies.new(dry_run: false).process # create it
#
# The seed file is all find_or_create_by!, so this is idempotent and safe to repeat. It is also
# the whole implementation: rather than restate the tree here and let the two copies drift, this
# loads the same file the other environments use.
class Onetime::SeedTaxonomies
  SEED_FILE = Rails.root.join("db", "seeds", "010_development_staging_test", "taxonomy_create.rb")

  def initialize(dry_run: true)
    @dry_run = dry_run
  end

  def process
    before = Taxonomy.pluck(:slug)

    # The seed file only reveals what it would write by writing, so the dry run applies it inside
    # a transaction and rolls back. Reporting against TAXONOMY_LABELS instead would overstate the
    # answer: the label hash carries keys with no seed row (entertainment, video).
    created = nil
    Taxonomy.transaction do
      load(SEED_FILE.to_s, true)
      created = Taxonomy.pluck(:slug) - before
      raise ActiveRecord::Rollback if dry_run
    end

    Rails.logger.info("[SeedTaxonomies] #{dry_run ? "would create" : "created"} #{created.size} taxonomy row(s): #{created.inspect}")
    created
  end

  private
    attr_reader :dry_run
end
