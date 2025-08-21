# frozen_string_literal: true

require "spec_helper"

describe "RecommendationsScenario", type: :system, js: true do
  before do
    @original_product = create(:product)
    @recommended_product = create(:product,
                                  user: create(:named_user),
                                  preview_url: "https://s3.amazonaws.com/gumroad-specs/specs/kFDzu.png")
    3.times do |i|
      create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @original_product)
      create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @recommended_product)
    end
    Link.import(refresh: true, force: true)
    recreate_model_index(ProductPageView)
  end

  it "records discover purchases", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    visit "/l/#{@recommended_product.unique_permalink}?recommended_by=discover"

    Timeout.timeout(Capybara.default_max_wait_time) do
      until EsClient.count(index: ProductPageView.index_name)["count"] == 1
        sleep 0.5
      end
    end

    page_view = EsClient.search(index: ProductPageView.index_name, size: 1)["hits"]["hits"][0]["_source"]
    expect(page_view).to include(
      "product_id" => @recommended_product.id,
      "referrer_domain" => "recommended_by_gumroad"
    )

    expect do
      add_to_cart(@recommended_product, recommended_by: "discover")
      check_out(@recommended_product)
    end.to change { Purchase.successful.count }.by(1)

    purchase = Purchase.last
    expect(purchase.link_id).to eq @recommended_product.id
    expect(purchase.was_product_recommended).to be(true)
  end

  it "records the recommender_model_name if present", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    visit "/l/#{@recommended_product.unique_permalink}?recommended_by=discover&recommender_model_name=#{RecommendedProductsService::MODEL_SALES}"

    expect do
      add_to_cart(@recommended_product)
      check_out(@recommended_product)
    end.to change { Purchase.successful.count }.by(1)

    purchase = Purchase.last!
    expect(purchase.link_id).to eq @recommended_product.id
    expect(purchase.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
    expect(purchase.recommended_purchase_info.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
  end

  def assert_buying_with_recommended_by_from_profile_page(recommended_by:)
    user = @recommended_product.user
    section = create(:seller_profile_products_section, seller: user, shown_products: [@recommended_product.id])
    create(:seller_profile, seller: user, json_data: { tabs: [{ name: "", sections: [section.id] }] })
    visit("/#{user.username}?recommended_by=#{recommended_by}")

    find_product_card(@recommended_product).click

    expect do
      add_to_cart(@recommended_product, recommended_by:, cart: true)
      check_out(@recommended_product)
    end.to change { Purchase.successful.count }.by(1)

    purchase = Purchase.last
    expect(purchase.link_id).to eq @recommended_product.id
    expect(purchase.was_product_recommended).to be(true)
    if recommended_by == "discover"
      expect(purchase.recommended_purchase_info.recommendation_type).to eq RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION
    elsif recommended_by == "search"
      expect(purchase.recommended_purchase_info.recommendation_type).to eq RecommendationType::GUMROAD_SEARCH_RECOMMENDATION
    end
  end

  it "records the correct recommendation info when a product is bought from a creator's profile which contains " \
     "'recommended_by=discover' in the URL" do
    assert_buying_with_recommended_by_from_profile_page(recommended_by: "discover")
  end

  it "records the correct recommendation info when a product is bought from a creator's profile which contains " \
     "'recommended_by=search' in the URL" do
    assert_buying_with_recommended_by_from_profile_page(recommended_by: "search")
  end

  context "when a custom fee is set for the seller" do
    before do
      @recommended_product.user.update!(custom_fee_per_thousand: 50, user_risk_state: "compliant")
      @recommended_product.update!(taxonomy: Taxonomy.find_by!(slug: "design"))
    end

    it "charges the regular discover fee and not custom fee" do
      visit "/l/#{@recommended_product.unique_permalink}?recommended_by=discover&recommender_model_name=#{RecommendedProductsService::MODEL_SALES}"

      expect do
        add_to_cart(@recommended_product, recommended_by: "discover")
        check_out(@recommended_product)
      end.to change { Purchase.successful.count }.by(1)

      purchase = Purchase.last!
      expect(purchase.link_id).to eq @recommended_product.id
      expect(purchase.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
      expect(purchase.recommended_purchase_info.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
      expect(purchase.was_discover_fee_charged?).to eq(true)
      expect(purchase.custom_fee_per_thousand).to be_nil
      expect(purchase.fee_cents).to eq(30) # 30% discover fee
    end
  end

  describe "more like this" do
    let(:seller1) { create(:recommendable_user) }
    let(:seller2) { create(:named_user, recommendation_type: User::RecommendationType::NO_RECOMMENDATIONS) }
    let(:buyer) { create(:buyer_user) }

    let(:seller1_products) do
      build_list :product, 5, user: seller1 do |product, i|
        product.name = "Seller 1 Product #{i}"
        product.save!
      end
    end
    let(:seller2_products) do
      build_list :product, 2, user: seller2 do |product, i|
        product.name = "Seller 2 Product #{i}"
        product.save!
      end
    end

    before do
      create(:purchase, purchaser: buyer, link: seller1_products.first)

      seller1_products.drop(1).each_with_index do |product, i|
        SalesRelatedProductsInfo.update_sales_counts(product_id: seller1_products.first.id, related_product_ids: [product.id], increment: i + 1)
      end
      SalesRelatedProductsInfo.update_sales_counts(product_id: seller2_products.first.id, related_product_ids: seller2_products.drop(1).map(&:id), increment: 1)

      rebuild_srpis_cache
    end

    it "displays the correct recommended products and records the correct recommendation info on purchase" do
      login_as buyer
      visit seller2_products.first.long_url
      add_to_cart(seller2_products.first)

      expect(page).to_not have_section("Customers who bought this item also bought")

      visit seller1_products.first.long_url
      add_to_cart(seller1_products.first, logged_in_user: buyer)

      within_section "Customers who bought these items also bought" do
        expect(page).to have_selector("article:nth-child(1)", text: "Seller 1 Product 4")
        expect(page).to have_selector("article:nth-child(2)", text: "Seller 1 Product 3")
        expect(page).to have_selector("article:nth-child(3)", text: "Seller 1 Product 2")
        expect(page).to have_selector("article:nth-child(4)", text: "Seller 1 Product 1")

        expect(page).to_not have_text("Seller 2")

        click_on "Seller 1 Product 4"
      end

      add_to_cart(seller1_products.last, cart: true)
      within_section "Customers who bought these items also bought" do
        expect(page).to have_selector("article:nth-child(1)", text: "Seller 1 Product 3")
        expect(page).to have_selector("article:nth-child(2)", text: "Seller 1 Product 2")
        expect(page).to have_selector("article:nth-child(3)", text: "Seller 1 Product 1")

        expect(page).to_not have_text("Seller 2")
      end

      check_out(seller1_products.last, logged_in_user: buyer)

      purchase = Purchase.third_to_last
      expect(purchase.link).to eq(seller1_products.last)
      expect(purchase.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
      expect(purchase.recommended_purchase_info.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
      expect(purchase.recommended_purchase_info.recommendation_type).to eq(RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
    end

    context "when at least one creator has Gumroad affiliate recommendations enabled" do
      before do
        seller1.update!(recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)
        SalesRelatedProductsInfo.update_sales_counts(product_id: seller2_products.first.id, related_product_ids: [seller1_products.first.id], increment: 1000)
        rebuild_srpis_cache

        allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
      end

      it "recommends and attributes affiliate purchases for products with Gumroad affiliates enabled" do
        login_as buyer

        visit seller1_products.first.long_url
        add_to_cart(seller1_products.first, logged_in_user: buyer)

        click_on "Seller 2 Product 0"
        add_to_cart(seller2_products.first, logged_in_user: buyer, cart: true)
        check_out(seller2_products.first, logged_in_user: buyer)

        purchase = Purchase.second_to_last
        expect(purchase.link).to eq(seller2_products.first)
        expect(purchase.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
        expect(purchase.recommended_purchase_info.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
        expect(purchase.recommended_purchase_info.recommendation_type).to eq(RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
        expect(purchase.affiliate).to eq(seller1.global_affiliate)
      end
    end

    context "when a creator has direct affiliate recommendations enabled" do
      let!(:affiliate) { create(:direct_affiliate, seller: seller2, products: [seller2_products.first], affiliate_user: seller1) }

      before do
        seller1.update!(recommendation_type: User::RecommendationType::DIRECTLY_AFFILIATED_PRODUCTS)
        SalesRelatedProductsInfo.update_sales_counts(product_id: seller2_products.first.id, related_product_ids: [seller1_products.first.id], increment: 1000)
        rebuild_srpis_cache

        allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
      end

      it "it recommends and attributes affiliate purchases for products with Gumroad affiliates enabled" do
        login_as buyer

        visit seller1_products.first.long_url
        add_to_cart(seller1_products.first, logged_in_user: buyer)

        click_on "Seller 2 Product 0"
        add_to_cart(seller2_products.first, logged_in_user: buyer, cart: true)
        check_out(seller2_products.first, logged_in_user: buyer)

        purchase = Purchase.second_to_last
        expect(purchase.link).to eq(seller2_products.first)
        expect(purchase.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
        expect(purchase.recommended_purchase_info.recommender_model_name).to eq(RecommendedProductsService::MODEL_SALES)
        expect(purchase.recommended_purchase_info.recommendation_type).to eq(RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
        expect(purchase.affiliate).to eq(affiliate)
      end
    end

    context "when the product has increased discover placement" do
      before do
        seller1_products.first.update!(discover_fee_per_thousand: 400)
      end

      it "does not charge discover fees" do
        login_as buyer
        visit seller1_products.first.long_url
        add_to_cart(seller1_products.first, logged_in_user: buyer)

        click_on "Seller 1 Product 1"
        add_to_cart(seller1_products.second, logged_in_user: buyer, cart: true)
        check_out(seller1_products.second, logged_in_user: buyer)

        purchase = Purchase.second_to_last
        expect(purchase.link).to eq(seller1_products.second)
        expect(purchase.recommended_by).to eq(RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
        expect(purchase.was_discover_fee_charged?).to eq(false)
        expect(purchase.fee_cents).to eq(93)
      end
    end
  end
end
