# frozen_string_literal: true

module Workflow::AbandonedCartProducts
  extend ActiveSupport::Concern

  included do
    include Rails.application.routes.url_helpers
  end


  def abandoned_cart_products(only_product_and_variant_ids: false)
    return [] unless abandoned_cart_type?

    include_all_products = bought_products.blank? && bought_variants.blank?
    query = seller.links.visible_and_not_archived.includes(:alive_variants)
    query = query.includes(thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } }) if !only_product_and_variant_ids
    query.filter_map.filter_map do |product|
      next if not_bought_products&.include?(product.unique_permalink)

      has_selected_product_variant = bought_variants.present? && (bought_variants & product.alive_variants.map(&:external_id)).any?


      if include_all_products || has_selected_product_variant || bought_products&.include?(product.unique_permalink)
        variants = product.alive_variants.filter_map do
          next if not_bought_variants&.include?(_1.external_id)

          { external_id: _1.external_id, name: _1.name } if include_all_products || bought_products&.include?(product.unique_permalink) || bought_variants&.include?(_1.external_id)
        end

        if only_product_and_variant_ids
          [product.id, variants.map { ObfuscateIds.decrypt(_1[:external_id]) }]
        else
          {
            unique_permalink: product.unique_permalink,
            external_id: product.external_id,
            name: product.name,
            thumbnail_url: product.for_email_thumbnail_url,
            url: product.long_url,
            variants:,
            seller: {
              name: seller.display_name,
              avatar_url: seller.avatar_url,
              profile_url: seller.profile_url,
            }
          }
        end
      end
    end
  end
end
