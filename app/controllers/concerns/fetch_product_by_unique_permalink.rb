# frozen_string_literal: true

module FetchProductByUniquePermalink
  # Fetches a product by unique permalink (only!) identified via `id` or `link_id` params.
  # Requires the product's owner or an admin user to be logged in.
  #
  # This method shouldn't be used to fetch a product by custom_permalink because they are not
  # globally unique and if it's admin user accessing the page, we can't be sure which
  # creator's product should be shown.
  def fetch_product_by_unique_permalink
    unique_permalink = params[:id] || params[:link_id] || params[:product_id]
    e404 if unique_permalink.blank?

    @product = Link.find_by(unique_permalink:) || e404
  end
end
