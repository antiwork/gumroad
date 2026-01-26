# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe DiscoverController, inertia: true do
  render_views

  let(:discover_domain_with_protocol) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @product = create(:product, user: create(:user, name: "Gumstein"))
    sign_in @buyer
  end

  describe "#index" do
    it "renders the Discover/Index Inertia component with required props" do
      sign_in @buyer

      get :index

      expect(response).to be_successful
      expect_inertia.to render_component("Discover/Index")
      expect(inertia.props[:search_results]).to include(:products, :total)
      expect(inertia.props[:currency_code]).to eq(@buyer.currency_type)
      expect(inertia.props[:taxonomies_for_nav]).to be_an(Array)
      expect(inertia.props[:recommended_products]).to be_an(Array)
      expect(inertia.props[:curated_product_ids]).to be_an(Array)
      expect(inertia.props[:show_black_friday_hero]).to be_in([true, false])
      expect(inertia.props[:black_friday_offer_code]).to eq("BLACKFRIDAY2025")
    end

    it "renders the proper meta tags with no extra parameters" do
      get :index

      expect(response.body).to have_selector("title:contains('Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:type'][content='website']", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/']", visible: false)
    end

    it "renders the proper meta tags when a search query was submitted" do
      get :index, params: { query: "tests" }

      expect(response.body).to have_selector("title:contains('Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/?query=tests']", visible: false)
    end

    it "renders the proper meta tags when a specific tag has been selected" do
      get :index, params: { tags: "3d models" }

      description = "Browse over 0 3D assets including 3D models, CG textures, HDRI environments & more" \
                    " for VFX, game development, AR/VR, architecture, and animation."
      expect(response.body).to have_selector("title:contains('Professional 3D Modeling Assets | Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/?tags=3d+models']", visible: false)
    end

    it "renders the proper meta tags when a specific tag has been selected" do
      get :index, params: { tags: "3d      - mODELs" }

      description = "Browse over 0 3D assets including 3D models, CG textures, HDRI environments & more" \
                    " for VFX, game development, AR/VR, architecture, and animation."
      expect(response.body).to have_selector("title:contains('Professional 3D Modeling Assets | Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/?tags=3d+models']", visible: false)
    end

    it "stores the search query" do
      cookies[:_gumroad_guid] = "custom_guid"

      expect do
        get :index, params: { taxonomy: "3d/3d-modeling", query: "stl files" }
      end.to change(DiscoverSearch, :count).by(1).and change(DiscoverSearchSuggestion, :count).by(1)

      expect(DiscoverSearch.last!.attributes).to include(
        "query" => "stl files",
        "taxonomy_id" => Taxonomy.find_by_path(["3d", "3d-modeling"]).id,
        "user_id" => @buyer.id,
        "ip_address" => "0.0.0.0",
        "browser_guid" => "custom_guid",
        "autocomplete" => false
      )
      expect(DiscoverSearch.last!.discover_search_suggestion).to be_present
    end

    context "meta description total count" do
      let(:total_products) { Link::RECOMMENDED_PRODUCTS_PER_PAGE + 2 }

      before do
        total_products.times do |i|
          product = create(:product, :recommendable)
          product.tag!("3d models")
        end
        Link.import(refresh: true, force: true)
      end

      it "renders the correct total search result size in the meta description" do
        get :index, params: { tags: "3d models" }

        description = "Browse over #{total_products} 3D assets including 3D models, CG textures, HDRI environments & more" \
                      " for VFX, game development, AR/VR, architecture, and animation."
        expect(response.body).to have_selector("meta[property='og:description'][content='#{description}']", visible: false)
        expect(response.body).to have_selector("meta[name='description'][content='#{description}']", visible: false)
      end
    end
  end

  describe "#recommended_products" do
    it "returns recommended products when taxonomy is blank" do
      cart = create(:cart, user: @buyer)
      create(:cart_product, cart:, product: @product)
      recommended_product = create(:product)

      expect(RecommendedProducts::DiscoverService).to receive(:fetch).with(
        purchaser: @buyer,
        cart_product_ids: [@product.id],
        recommender_model_name: RecommendedProductsService::MODEL_SALES,
      ).and_return([RecommendedProducts::ProductInfo.new(recommended_product)])

      get :recommended_products, format: :json

      expect(response).to be_successful
      expect(response.parsed_body).to eq([ProductPresenter.card_for_web(product: recommended_product, request:).as_json])
    end

    it "returns random products from all top taxonomies when taxonomy is blank and no curated products" do
      top_taxonomies = Taxonomy.roots.to_a
      all_top_products = []

      top_taxonomies.each do |taxonomy|
        products = create_list(:product, 3, :recommendable, taxonomy:)
        all_top_products.concat(products)
      end

      Link.import(refresh: true, force: true)

      allow(Rails.cache).to receive(:fetch).and_call_original
      allow(Rails.cache).to receive(:fetch).with("discover_all_top_products", expires_in: 1.day).and_return(all_top_products)

      sampled_products = all_top_products.first(DiscoverController::RECOMMENDED_PRODUCTS_COUNT)
      allow(all_top_products).to receive(:sample).with(DiscoverController::RECOMMENDED_PRODUCTS_COUNT).and_return(sampled_products)

      get :recommended_products, format: :json

      expect(response).to be_successful

      expected_products = sampled_products.map do |product|
        ProductPresenter.card_for_web(
          product:,
          request:,
          target: Product::Layout::DISCOVER,
          recommended_by: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION
        ).as_json
      end

      expect(response.parsed_body).to match_array(expected_products)
    end

    it "returns search results when taxonomy is present" do
      taxonomy = Taxonomy.find_by!(slug: "3d")
      other_taxonomy = Taxonomy.find_or_create_by!(slug: "other")
      taxonomy_product = create(:product, :recommendable, taxonomy:)
      child_taxonomy_product = create(:product, :recommendable, taxonomy: taxonomy.children.first)
      create(:product, :recommendable, taxonomy: other_taxonomy)
      Link.import(refresh: true, force: true)

      get :recommended_products, params: { taxonomy: "3d" }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body).to contain_exactly(
        ProductPresenter.card_for_web(product: taxonomy_product, request:, target: Product::Layout::DISCOVER, recommended_by: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION).as_json,
        ProductPresenter.card_for_web(product: child_taxonomy_product, request:, target: Product::Layout::DISCOVER, recommended_by: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION).as_json,
      )
    end
  end
end
