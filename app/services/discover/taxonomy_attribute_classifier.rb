# frozen_string_literal: true

# Auto-classifies a product's taxonomy attribute values from signals sellers already provide
# (file extensions today; description/tags/cover image are future classifier registrations),
# so Discover facets have coverage without requiring every seller to fill in the Share tab.
#
# One classifier per taxonomy slug path, mirroring `TaxonomyAttributeDefinitions`'s registry so
# adding a category is a data-only change. Absence from `CLASSIFIERS` is normal — most
# categories have no automatic signal yet, and `classify!` is then a no-op.
module Discover
  class TaxonomyAttributeClassifier
    CLASSIFIERS = {
      "design/fonts" => Discover::FontsAttributeClassifier,
    }.freeze

    def self.classify!(link)
      classifier = classifier_for(link)
      return clear_inferred_values(link) if classifier.nil?

      classifier.new(link).classify!
    end

    # dry_run: computes the values a real run would write, without persisting them — the
    # backfill's distribution report and the per-product preview both read this.
    def self.inferred_values_for(link)
      classifier = classifier_for(link)
      return {} if classifier.nil?

      classifier.new(link).inferred_values
    end

    def self.classifier_for(link)
      taxonomy = link.taxonomy
      return nil if taxonomy.nil?

      CLASSIFIERS[taxonomy.ancestry_path.join("/")]
    end

    # A product moved off a classified taxonomy (or has none) must not keep a prior
    # classifier's inferred values — nothing re-runs classify! for it again to clear them.
    def self.clear_inferred_values(link)
      link.inferred_taxonomy_attribute_values.present? ? link.save_inferred_taxonomy_attribute_values({}) : false
    end
  end
end
