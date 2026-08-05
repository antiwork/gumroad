# frozen_string_literal: true

# Backfills `inferred_taxonomy_attribute_values` for existing products by re-running the
# registered classifier (`Discover::TaxonomyAttributeClassifier`) — the create/update hooks
# in Product::Taxonomies and ProductFile only cover products touched going forward
# (gumroad-private#1788).
#
# Dry-run by default: reports the distribution of what WOULD be written (per-attribute counts,
# not just a total), matching the issue's "dry-run mode that reports the distribution before
# anything is written" requirement. Never touches `taxonomy_attribute_values` (seller-entered).
#
#   Onetime::BackfillTaxonomyAttributeClassification.process                 # dry run
#   Onetime::BackfillTaxonomyAttributeClassification.process(dry_run: false) # writes
module Onetime
  class BackfillTaxonomyAttributeClassification
    BATCH_SIZE = 1_000

    def self.process(dry_run: true, batch_size: BATCH_SIZE)
      new(dry_run:, batch_size:).process
    end

    def initialize(dry_run: true, batch_size: BATCH_SIZE)
      @dry_run = dry_run
      @batch_size = batch_size
      @stats = Hash.new(0)
      @value_distribution = Hash.new { |h, k| h[k] = Hash.new(0) }
    end

    def process
      Discover::TaxonomyAttributeClassifier::CLASSIFIERS.each_key do |slug_path|
        taxonomy = TaxonomyAttributeDefinitions.taxonomy_for(slug_path)
        next if taxonomy.nil?

        backfill_taxonomy(taxonomy)
      end

      @stats[:dry_run] = @dry_run
      Rails.logger.info("[BackfillTaxonomyAttributeClassification] #{@stats.to_h} distribution=#{@value_distribution.transform_values(&:to_h)}")
      { stats: @stats.to_h, distribution: @value_distribution.transform_values(&:to_h) }
    end

    private
      def backfill_taxonomy(taxonomy)
        Link.alive.where(taxonomy_id: taxonomy.id).find_each(batch_size: @batch_size) do |link|
          ReplicaLagWatcher.watch
          backfill(link)
        rescue => e
          @stats[:errors] += 1
          Rails.logger.error("[BackfillTaxonomyAttributeClassification] link=#{link.id} error=#{e.class}: #{e.message}")
        end
      end

      def backfill(link)
        inferred = Discover::TaxonomyAttributeClassifier.inferred_values_for(link)

        if inferred.empty?
          return tick(:skipped_no_signal) if @dry_run || link.inferred_taxonomy_attribute_values.blank?
          return link.save_inferred_taxonomy_attribute_values({}) ? tick(:cleared) : tick(:save_failed)
        end

        inferred.each { |name, value| @value_distribution[name][value.to_s] += 1 }
        return tick(:would_infer) if @dry_run

        link.save_inferred_taxonomy_attribute_values(inferred) ? tick(:inferred) : tick(:save_failed)
      end

      def tick(key)
        @stats[key] += 1
        nil
      end
  end
end
