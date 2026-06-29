# frozen_string_literal: true

# One-time cleanup for the leak fixed forward in Link#remove_from_profile_sections!
# (issue gumroad-private#685): before that fix, soft-deleting a product never
# stripped its id from SellerProfileProductsSection.shown_products, so sections
# kept pointing at dead product ids. The public profile already ignores those ids
# (products render from search, which only returns alive products), so this is
# data hygiene rather than a user-facing fix — which is why it runs as an
# off-deploy background job instead of a migration.
#
# Idempotent and safe to re-run: it only ever removes ids whose products are
# soft-deleted, recomputes under the seller's profile lock so it can't clobber a
# concurrent edit, and isolates each section so one malformed legacy row can't
# abort the whole run.
module Onetime
  class BackfillOrphanedShownProductsInProfileSections
    BATCH_SIZE = 500

    def self.process(batch_size: BATCH_SIZE)
      new(batch_size:).process
    end

    def initialize(batch_size: BATCH_SIZE)
      @batch_size = batch_size
    end

    def process
      cleaned_sections = 0

      SellerProfileProductsSection.find_each(batch_size: @batch_size) do |section|
        shown = shown_product_ids(section)
        next if shown.empty?

        # Cheap pre-check outside the lock: skip sections that have no dead ids.
        alive_ids = alive_ids_among(shown)
        next if shown.all? { |id| alive_ids.include?(id) }

        # Orphaned section whose seller was hard-deleted: there's nothing to lock
        # against, so skip it explicitly rather than letting the lock call raise.
        seller = section.seller
        next if seller.nil?

        # Re-read and rewrite under the seller's profile lock, recomputing against
        # the current array, so a concurrent profile edit can't be overwritten.
        seller.with_profile_sections_lock do
          section.reload
          shown = shown_product_ids(section)
          next if shown.empty?

          alive_ids = alive_ids_among(shown)
          cleaned = shown.select { |id| alive_ids.include?(id) }
          next if cleaned.length == shown.length

          section.update!(shown_products: cleaned)
          cleaned_sections += 1
        end
      rescue => e
        # One bad row (legacy/corrupt json_data, validation failure) shouldn't stall
        # the whole cleanup; log it and move on. The job is safe to re-run.
        Rails.logger.warn("[BackfillOrphanedShownProductsInProfileSections] skipped section #{section.id}: #{e.class}: #{e.message}")
      end

      Rails.logger.info("[BackfillOrphanedShownProductsInProfileSections] cleaned #{cleaned_sections} section(s)")
      cleaned_sections
    end

    private
      # json_data is nullable and legacy rows can hold non-Hash/non-Array shapes,
      # so read defensively rather than trusting the generated shown_products accessor.
      def shown_product_ids(section)
        data = section.json_data
        return [] unless data.is_a?(Hash)

        shown = data["shown_products"]
        shown.is_a?(Array) ? shown : []
      end

      def alive_ids_among(product_ids)
        Link.where(id: product_ids, deleted_at: nil).pluck(:id).to_set
      end
  end
end
