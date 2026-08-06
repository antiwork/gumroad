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
      registered_taxonomy_ids = []

      Discover::TaxonomyAttributeClassifier::CLASSIFIERS.each_key do |slug_path|
        taxonomy = TaxonomyAttributeDefinitions.taxonomy_for(slug_path)
        next if taxonomy.nil?

        registered_taxonomy_ids << taxonomy.id
        backfill_taxonomy(taxonomy)
      end

      cleanup_orphaned_inferred_values(registered_taxonomy_ids)

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

      # A product whose taxonomy was never registered with a classifier (moved off one, or
      # never had one) is invisible to backfill_taxonomy above, which only ever scopes to
      # registered taxonomy ids. The json_data LIKE prefilter avoids a full-table scan; it
      # can't false-negative since every write path serializes the key by this exact name.
      def cleanup_orphaned_inferred_values(registered_taxonomy_ids)
        scope = Link.alive.where("json_data LIKE ?", "%inferred_taxonomy_attribute_values%")
        scope = scope.where("taxonomy_id NOT IN (?) OR taxonomy_id IS NULL", registered_taxonomy_ids) if registered_taxonomy_ids.present?

        scope.find_each(batch_size: @batch_size) do |link|
          ReplicaLagWatcher.watch
          next if link.inferred_taxonomy_attribute_values.blank?

          if @dry_run
            tick(:would_clear_orphaned)
          else
            # A taxonomy move can land between select and write and re-fire
            # classify_taxonomy_attributes (Product::Taxonomies after_commit) with fresh
            # inferred values. Reload-then-check-then-save still races: the after_commit
            # can land between the check and this instance's save. Lock the row for the
            # whole check+write so no classifier save can interleave.
            outcome = Link.transaction do
              locked = Link.lock.find_by(id: link.id)
              next :missing unless locked

              still_orphaned = registered_taxonomy_ids.blank? || registered_taxonomy_ids.exclude?(locked.taxonomy_id)
              next :no_longer_orphaned unless still_orphaned && locked.inferred_taxonomy_attribute_values.present?

              locked.save_inferred_taxonomy_attribute_values({}) ? :cleared : :save_failed
            end
            tick(:cleared_orphaned) if outcome == :cleared
            tick(:save_failed) if outcome == :save_failed
          end
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
