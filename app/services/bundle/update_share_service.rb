# frozen_string_literal: true

class Bundle::UpdateShareService
  def initialize(bundle:, taxonomy_id: nil, tags: nil, section_ids: nil, display_product_reviews: nil, is_adult: nil)
    @bundle = bundle
    @taxonomy_id = taxonomy_id
    @tags = tags
    @section_ids = section_ids
    @display_product_reviews = display_product_reviews
    @is_adult = is_adult
  end

  def perform
    @bundle.assign_attributes(
      taxonomy_id: @taxonomy_id,
      display_product_reviews: @display_product_reviews,
      is_adult: @is_adult
    )

    @bundle.save_tags!(@tags || [])
    @bundle.show_in_sections!(@section_ids || [])

    @bundle.save!
    @bundle
  end
end
