# frozen_string_literal: true

# Intentionally a no-op.
#
# This started as an inline data backfill (stripping soft-deleted product ids
# out of SellerProfileProductsSection.shown_products, the leak fixed forward in
# Link#remove_from_profile_sections!, issue gumroad-private#685). As a
# deploy-time migration it held the migration advisory lock for the full
# row-by-row backfill, which stalled a production deploy.
#
# The cleanup now lives in a background job that runs off the deploy path:
# BackfillOrphanedShownProductsInProfileSectionsJob
# (Onetime::BackfillOrphanedShownProductsInProfileSections), enqueued manually.
# This migration stays so the version records cleanly across environments; it
# performs no work.
class BackfillOrphanedShownProductsInProfileSections < ActiveRecord::Migration[7.1]
  def up
  end

  def down
  end
end
