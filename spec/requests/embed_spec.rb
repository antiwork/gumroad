# frozen_string_literal: true

require "spec_helper"

describe "Embed scenario", type: :system, js: true do
  include EmbedHelpers

  after(:all) { cleanup_embed_artifacts }

  let(:product) { create(:physical_product) }
  let!(:js_nonce) { SecureRandom.base64(32).chomp }

  it "accepts product URL" do
    product = create(:product)

    visit(create_embed_page(product, url: product.long_url, gumroad_params: "&email=sam@test.com", outbound: false))

    within_frame { click_on "Add to cart" }

    check_out(product)
  end

  it "accepts affiliated product URL with query params" do
    affiliate_user = create(:affiliate_user)
    pwyw_product = create(:product, price_cents: 0, customizable_price: true)
    direct_affiliate = create(:direct_affiliate, affiliate_user:, seller: pwyw_product.user, affiliate_basis_points: 1000, products: [pwyw_product])

    visit(create_embed_page(pwyw_product, url: "#{direct_affiliate.referral_url_for_product(pwyw_product)}?email=john@test.com", gumroad_params: "&price=75", outbound: false))

    within_frame { click_on "Add to cart" }

    expect do
      check_out(pwyw_product, email: nil)
    end.to change { AffiliateCredit.count }.from(0).to(1)

    purchase = pwyw_product.sales.successful.last
    expect(purchase.email).to eq("john@test.com")
    expect(purchase.price_cents).to eq(7500)
    expect(purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
    expect(purchase.affiliate_credit.amount_cents).to eq(645)
  end

  it "embeds affiliated product with destination URL" do
    affiliate_user = create(:affiliate_user)
    pwyw_product = create(:product, price_cents: 0, customizable_price: true)
    direct_affiliate = create(:direct_affiliate, affiliate_user:, seller: pwyw_product.user, affiliate_basis_points: 1000, products: [pwyw_product], destination_url: "https://gumroad.com")

    visit(create_embed_page(pwyw_product, url: "#{direct_affiliate.referral_url_for_product(pwyw_product)}?", outbound: false))

    within_frame do
      fill_in "Name a fair price", with: 75
      click_on "Add to cart"
    end

    expect do
      check_out(pwyw_product)
    end.to change { AffiliateCredit.count }.from(0).to(1)

    purchase = pwyw_product.sales.successful.last
    expect(purchase.email).to eq("test@gumroad.com")
    expect(purchase.price_cents).to eq(7500)
    expect(purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
    expect(purchase.affiliate_credit.amount_cents).to eq(645)
  end

  it "embeds a product that has a custom permalink" do
    product = create(:product, custom_permalink: "custom")

    visit(create_embed_page(product, url: short_link_url(product, host: "#{PROTOCOL}://#{DOMAIN}"), outbound: false))

    within_frame { click_on "Add to cart" }

    check_out(product)
  end

  it "embeds a product by accepting only 'data-gumroad-product-id' attribute and without inserting an anchor tag" do
    product = create(:product)

    visit(create_embed_page(product, insert_anchor_tag: false, outbound: false))

    within_frame { click_on "Add to cart" }

    check_out(product)
  end

  context "discount code in URL" do
    let(:offer_code) { create(:offer_code, user: product.user, products: [product]) }

    it "applies the discount code" do
      visit(create_embed_page(product, url: "#{product.long_url}/#{offer_code.code}", outbound: false))

      within_frame do
        expect(page).to have_status(text: "$1 off will be applied at checkout (Code SXSW)")
        click_on "Add to cart"
      end

      check_out(product, is_free: true)

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.offer_code).to eq(offer_code)
    end
  end

  context "when an affiliated product purchased from a browser that doesn't support setting third-party affiliate cookie" do
    let(:affiliate_user) { create(:affiliate_user) }
    let(:product) { create(:product, price_cents: 7500) }
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: product.user, affiliate_basis_points: 1000, products: [product]) }

    before(:each) do
      expect_any_instance_of(OrdersController).to receive(:affiliate_from_cookies).with(an_instance_of(Link)).and_return(nil)
    end

    it "successfully credits the affiliate commission for the product bought using its affiliated product URL" do
      visit(create_embed_page(product, url: direct_affiliate.referral_url_for_product(product), outbound: false))

      within_frame { click_on "Add to cart" }

      check_out(product)

      purchase = product.sales.successful.last
      expect(purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
      expect(purchase.affiliate_credit.amount_cents).to eq(645)
    end

    Affiliate::QUERY_PARAMS.each do |query_param|
      it "successfully credits the affiliate commission for the product bought from a page that contains '#{query_param}' query parameter" do
        visit(create_embed_page(product, url: short_link_url(product, host: UrlService.domain_with_protocol), outbound: false, query_params: { query_param => direct_affiliate.external_id_numeric }))

        within_frame { click_on "Add to cart" }

        check_out(product)

        purchase = product.sales.successful.last
        expect(purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
        expect(purchase.affiliate_credit.amount_cents).to eq(645)
      end
    end
  end

  it "prefils the values for quantity, variant, price, and custom fields from the URL" do
    physical_skus_product = create(:physical_product, skus_enabled: true, price_cents: 0, customizable_price: true)
    variant_category_1 = create(:variant_category, link: physical_skus_product)
    %w[Red Blue Green].each { |name| create(:variant, name:, variant_category: variant_category_1) }
    variant_category_2 = create(:variant_category, link: physical_skus_product)
    ["Small", "Medium", "Large", "Extra Large"].each { |name| create(:variant, name:, variant_category: variant_category_2) }
    variant_category_3 = create(:variant_category, link: physical_skus_product)
    %w[Polo Round].each { |name| create(:variant, name:, variant_category: variant_category_3) }
    Product::SkusUpdaterService.new(product: physical_skus_product).perform

    physical_skus_product.custom_fields << [
      create(:custom_field, name: "Age"),
      create(:custom_field, name: "Gender")
    ]
    physical_skus_product.save!

    embed_page_url = create_embed_page(physical_skus_product, template_name: "embed_page.html.erb", outbound: false, gumroad_params: "quantity=2&price=3&Age=21&Gender=Male&option=#{physical_skus_product.skus.find_by(name: "Blue - Extra Large - Polo").external_id}")
    visit(embed_page_url)

    within_frame do
      expect(page).to have_radio_button("Blue - Extra Large - Polo", checked: true)
      expect(page).to have_field("Quantity", with: 2)
      expect(page).to have_field("Name a fair price", with: 3)
      click_on "Add to cart"
    end

    expect(page).to have_field("Age", with: "21")
    expect(page).to have_field("Gender", with: "Male")

    expect do
      check_out(physical_skus_product)
    end.to change { Purchase.successful.count }.by(1)
  end
end
