# frozen_string_literal: true

module AffiliatesHelper
  def affiliate_products_select_data(affiliate, products)
    tag_ids = products.each_with_object([]) do |product, selected|
      selected << product.external_id if affiliate.products.exists? && affiliate.products.include?(product)
    end
    tag_list = products.map { |product| { id: product.external_id, label: product.name } }
    [tag_ids, tag_list]
  end
end
