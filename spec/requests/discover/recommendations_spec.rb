# frozen_string_literal: true

require "spec_helper"

describe("Discover recommendations", js: true, type: :system) do
  let(:host) { UrlService.discover_domain_with_protocol }
  let(:user) { create(:buyer_user) }
  let(:product) { create(:product) }
  let(:products) do
    create_list(:product, 5) do |product, i|
      product.name = "Product #{i}"
      product.save!
    end
  end

  it "recommends products and correctly tracks the recommender model name" do
    allow(RecommendedProductsService).to receive(:fetch).and_return(Link.where(id: products.map(&:id)))
    visit discover_url(host:)

    within_section "Recommended", section_element: :section do
      click_on products.first.name
    end
    recommender_model_name = CGI.parse(page.current_url)["recommender_model_name"].first
    add_to_cart(products.first, cart: true)
    check_out(products.first)

    purchase = Purchase.last
    expect(purchase.recommended_purchase_info.recommendation_type).to eq(RecommendationType::GUMROAD_PRODUCTS_FOR_YOU_RECOMMENDATION)
    expect(purchase.recommender_model_name).to eq(recommender_model_name)
  end

  it "shows top products when there are no personalized recommendations" do
    searchable_product = create(:product, :recommendable, name: "searchable product")
    index_model_records(Link)

    allow(RecommendedProductsService).to receive(:fetch).and_return(Link.none)
    visit discover_url(host:)
    expect(page).to_not have_text("Recommended")

    within_section "Featured products", section_element: :section do
      click_on searchable_product.name
    end
    add_to_cart(searchable_product, cart: true)
    check_out(searchable_product)

    purchase = Purchase.last
    expect(purchase.recommended_purchase_info.recommendation_type).to eq(RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION)
  end

  it "boosts curated products to the top of the search results when they overflow the carousel" do
    curated_products = create_list(:product, 10, :recommendable) { _1.update!(name: "Curated #{_2}") }
    other_products = 7.times.map { |i| create(:product, :recommendable, price_cents: 10_00 * (i + 1), name: "Other #{i}") }
    allow(RecommendedProductsService).to receive(:fetch).and_return(Link.where(id: curated_products.map(&:id)))
    stub_const("DiscoverController::INITIAL_PRODUCTS_COUNT", 9)

    Purchase.import(refresh: true, force: true)
    Link.import(refresh: true, force: true)

    login_as user
    visit discover_url(host:)

    within_section "Recommended", section_element: :section do
      expect_product_cards_in_order(curated_products.first(8))
    end

    within_section "Curated for you", section_element: :section do
      expect_product_cards_in_order(curated_products.last(2) + other_products.reverse)
    end
  end
end
