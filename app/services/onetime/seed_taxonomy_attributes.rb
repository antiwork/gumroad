# frozen_string_literal: true

# Applies `TaxonomyAttributeDefinitions` to whatever environment it runs in.
#
# Existing rows are updated in place rather than recreated: `TaxonomyAttribute#name` is the ES
# filter-token prefix, so destroying and re-inserting a row would orphan every product value
# already indexed under it. Rows present in the DB but absent from the registry are deactivated,
# not deleted, for the same reason.
module Onetime
  class SeedTaxonomyAttributes
    def self.process(dry_run: true)
      new.process(dry_run:)
    end

    def process(dry_run: true)
      created = 0
      updated = 0
      deactivated = 0

      TaxonomyAttributeDefinitions.each_taxonomy_with_definitions do |taxonomy, definitions|
        definitions.each do |definition|
          attribute = TaxonomyAttribute.find_by(taxonomy:, name: definition[:name])

          if attribute.nil?
            created += 1
            puts "CREATE #{taxonomy.slug}/#{definition[:name]}"
            TaxonomyAttribute.create!(definition.merge(taxonomy:, active: true)) unless dry_run
            next
          end

          attribute.assign_attributes(definition.merge(active: true))
          next unless attribute.changed?

          updated += 1
          puts "UPDATE #{taxonomy.slug}/#{definition[:name]} #{attribute.changes.inspect}"
          attribute.save! unless dry_run
        end

        stale = TaxonomyAttribute.where(taxonomy:, active: true).where.not(name: definitions.map { _1[:name] })
        stale.each do |attribute|
          deactivated += 1
          puts "DEACTIVATE #{taxonomy.slug}/#{attribute.name}"
          attribute.update!(active: false) unless dry_run
        end
      end

      puts "#{dry_run ? 'DRY RUN' : 'APPLIED'} created=#{created} updated=#{updated} deactivated=#{deactivated}"
      { created:, updated:, deactivated: }
    end
  end
end
