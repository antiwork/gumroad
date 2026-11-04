# frozen_string_literal: true

class Bundle::UpdateShareService
  def initialize(bundle:, taxonomy_id: nil, tags: nil, section_ids: nil, display_product_reviews: nil, hide_bundle_product_reviews: nil, is_adult: nil)
    @bundle = bundle
    @taxonomy_id = taxonomy_id
    @tags = tags
    @section_ids = section_ids
    @display_product_reviews = display_product_reviews
    @hide_bundle_product_reviews = hide_bundle_product_reviews
    @is_adult = is_adult
  end

  def perform
    attributes = {
      taxonomy_id: @taxonomy_id,
      display_product_reviews: @display_product_reviews,
      is_adult: @is_adult
    }
    attributes[:hide_bundle_product_reviews] = @hide_bundle_product_reviews unless @hide_bundle_product_reviews.nil?
    @bundle.assign_attributes(attributes)

    @bundle.save_tags!(@tags || [])
    # Saved (locking the bundle's row) before the profile lock, the order the product sections writer
    # takes them, so the two cannot deadlock.
    @bundle.save!
    @bundle.show_in_sections!(@section_ids || [])

    @bundle
  end
end
