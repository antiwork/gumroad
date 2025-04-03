# frozen_string_literal: true

class ProductTagging < ApplicationRecord
  belongs_to :tag, optional: true
  belongs_to :product, class_name: "Link", optional: true

  validates_uniqueness_of :product_id, scope: :tag_id

  scope :owned_by_user, lambda { |user|
    joins(:product).where(links: { user_id: user.id })
  }
  scope :has_tag_name, lambda { |name|
    joins(:tag).where(tags: { name: })
  }
  scope :sorted_by_tags_usage_for_products, lambda { |products|
    join_products_on = "products_subq.id = product_taggings.product_id"
    products = products.select(:id)
    select("product_taggings.tag_id, count(tag_id) as tag_count")
      .joins("INNER JOIN (#{products.to_sql}) products_subq ON #{join_products_on}")
      .group("tag_id")
      .order("tag_count DESC")
  }

  after_commit :update_product_search_index!

  def update_product_search_index!
    product&.enqueue_index_update_for(["tags"])
  end
end
