# frozen_string_literal: true

class SellerProfileProductsSection < SellerProfileSection
  def product_names
    # Prevents a full table scan (see https://github.com/gumroad/web/pull/26855)
    Link.where(user_id: seller_id, id: shown_products).pluck(:name)
  end
end
