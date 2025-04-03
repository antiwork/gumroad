# frozen_string_literal: true

class CreateProductPageViewIndex < ActiveRecord::Migration[6.1]
  def up
    if Rails.env.production? || Rails.env.staging?
      ProductPageView.__elasticsearch__.create_index!(index: "product_page_views_v1")
      EsClient.indices.put_alias(name: "product_page_views", index: "product_page_views_v1")
    else
      ProductPageView.__elasticsearch__.create_index!
    end
  end

  def down
    if Rails.env.production? || Rails.env.staging?
      EsClient.indices.delete_alias(name: "product_page_views", index: "product_page_views_v1")
      ProductPageView.__elasticsearch__.delete_index!(index: "product_page_views_v1")
    else
      ProductPageView.__elasticsearch__.delete_index!
    end
  end
end
