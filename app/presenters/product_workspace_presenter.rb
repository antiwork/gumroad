# frozen_string_literal: true

class ProductWorkspacePresenter
  include Rails.application.routes.url_helpers

  def initialize(product:, pundit_user:)
    @product = product
    @pundit_user = pundit_user
  end

  def props
    {
      product: product_props,
      readiness: readiness,
      sections: sections,
      settings_payments_url: settings_payments_path,
    }
  end

  private
    attr_reader :product, :pundit_user

    def seller
      pundit_user.seller
    end

    def seller_can_publish_products?
      return @seller_can_publish_products if defined?(@seller_can_publish_products)
      @seller_can_publish_products = seller.can_publish_products?
    end

    def readiness
      Product::Readiness.for(product:, seller_can_publish_products: seller_can_publish_products?)
    end

    def sections
      {
        "basics" => basics_complete?,
        "offer" => offer_complete?,
        "payments" => payments_complete?,
      }
    end

    def basics_complete?
      product.persisted? && product.name.present?
    end

    def offer_complete?
      product.price_cents.present? && product.has_content? && product.thumbnail_or_cover_url.present?
    end

    def payments_complete?
      seller_can_publish_products?
    end

    def product_props
      {
        "id" => product.id,
        "name" => product.name,
        "native_type" => product.native_type,
        "custom_summary" => product.custom_summary,
        "permalink" => product.unique_permalink,
        "edit_url" => edit_link_path(product),
        "url" => product.long_url,
        "thumbnail_url" => product.thumbnail_or_cover_url,
        "price_formatted" => product.price_formatted_including_rental_verbose,
      }
    end
end
