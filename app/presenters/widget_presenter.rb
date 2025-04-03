# frozen_string_literal: true

class WidgetPresenter
  include Rails.application.routes.url_helpers

  attr_reader :seller, :product

  def initialize(seller:, product: nil)
    @seller = seller
    @product = product
  end

  def widget_props
    {
      display_product_select: user_signed_in? && product.blank?,
      products: products.map { |product| product_props(product) },
      affiliated_products: affiliated_products.map { |product| affiliated_product_props(product) },
      default_product: product_props(default_product),
    }
  end

  def products
    @products ||= if user_signed_in?
      seller.links.alive.order(created_at: :desc).presence || demo_products
    else
      demo_products
    end
  end

  def affiliated_products
    @affiliated_products ||= if user_signed_in?
      seller.directly_affiliated_products
            .select("name, custom_permalink, unique_permalink, affiliates.id AS affiliate_id")
            .order("affiliates.created_at DESC")
    else
      Link.none
    end
  end

  private
    def demo_products
      [Link.fetch("demo")].compact
    end

    def user_signed_in?
      seller.present?
    end

    def default_product
      @_default_product ||= product.presence || products.first
    end

    def product_props(product)
      {
        name: product.name,
        script_base_url: non_affiliated_product_script_base_url,
        url: product_url(product, host: product_link_base_url),
        gumroad_domain_url: product_url(product, host: product_link_base_url(allow_custom_domain: false))
      }
    end

    def affiliated_product_props(product)
      referral_url = DirectAffiliate.new(id: product.affiliate_id).referral_url_for_product(product)
      {
        name: product.name,
        script_base_url: affiliated_product_script_base_url,
        url: referral_url,
        gumroad_domain_url: referral_url
      }
    end

    def product_url(product, host:)
      if product.user == seller
        short_link_url(product.general_permalink, host:)
      else
        # Demo product does not belong to user, don't use the user's subdomain or custom domain
        product.long_url
      end
    end

    def affiliated_product_script_base_url
      UrlService.root_domain_with_protocol
    end

    def non_affiliated_product_script_base_url
      UrlService.widget_script_base_url(seller:)
    end

    def product_link_base_url(allow_custom_domain: true)
      UrlService.widget_product_link_base_url(seller:, allow_custom_domain:)
    end
end
