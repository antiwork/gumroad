# frozen_string_literal: true

module OverlayHelpers
  def setup_overlay_data
    @creator = create(:user)
    @products = {
      thank_you: create(:product, price_cents: 8353, user: @creator, name: "Thank you - The Works of Edgar Gumstein"),
      offer_code: create(:product, user: @creator, price_cents: 700),
      pwyw: create(:product, user: @creator, price_cents: 0, customizable_price: true),
      subscription: create(:subscription_product_with_versions, user: @creator, subscription_duration: :monthly),
      vanilla: create(:product, user: @creator, price_cents: 507, name: "Vanilla - The Works of Edgar Gumstein"),
      with_custom_permalink: create(:product, user: @creator, custom_permalink: "custom"),
      variant: create(:product, user: @creator),
      yen: create(:product, user: @creator, price_currency_type: "jpy", price_cents: 934),
      physical: create(:physical_product, user: @creator, require_shipping: true, price_cents: 1325)
    }
    create(:offer_code, products: [@products[:offer_code]], amount_cents: 100)
    create(:price, link: @products[:subscription], recurrence: "quarterly", price_cents: 250)
    create(:price, link: @products[:subscription], recurrence: "yearly", price_cents: 800)
    variant_category = create(:variant_category, link: @products[:variant])
    %w[Wurble Hatstand].each { |name| create(:variant, name:, variant_category:) }
    @products[:physical].shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
  end

  def create_page(urls, single_mode = false, trigger_checkout: false, template_name: "overlay_page.html.erb", custom_domain_base_uri: nil, query_params: {})
    template = Rails.root.join("spec", "support", "fixtures", template_name)
    filename = Rails.root.join("public", "overlay_spec_page_#{urls.join('_').gsub(/[^a-zA-Z]/, '_')}.html")
    File.delete(filename) if File.exist?(filename)
    urls.map! { |url| url.start_with?("http") ? url : "#{PROTOCOL}://#{DOMAIN}/l/#{url}" }
    File.open(filename, "w") do |f|
      f.write(ERB.new(File.read(template)).result_with_hash(
        urls:,
        single_mode:,
        trigger_checkout:,
        js_nonce:,
        custom_domain_base_uri: custom_domain_base_uri.presence || UrlService.root_domain_with_protocol
      ))
    end
    "/#{filename.basename}?x=#{Time.current.to_i}&#{query_params.to_param}"
  end
end
