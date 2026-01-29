# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe DiscoverController, type: :controller, inertia: true do
  render_views

  let(:discover_domain_with_protocol) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @product = create(:product, user: create(:user, name: "Gumstein"))
    sign_in @buyer
  end

  describe "#index" do
    it "displays navigation" do
      sign_in @buyer

      get :index

      expect(inertia).to render_component("Discover/Index")
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

      root = Taxonomy.create!(slug: "3d")
      root.children.create!(slug: "3d-modeling")

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
      let(:total_products) { 3 }

      before do
        total_products.times do |i|
          product = create(:product, :with_films_taxonomy, user: create(:recommendable_user))
          product.tag!("3d models")
        end
        Link.import(refresh: true, force: true)
      end

      it "renders the correct total search result size in the meta description" do
        get :index, params: { tags: "3d models" }

        expect(response.body).to match(
          /Browse over \d+ 3D assets including 3D models, CG textures, HDRI environments (?:&amp;|&) more for VFX, game development, AR\/VR, architecture, and animation\./
        )
      end
    end

    context "inertia props" do
      it "passes required props to the Inertia component" do
        get :index

        expect(inertia).to render_component("Discover/Index")
        expect(inertia.props).to include(
          :search_results,
          :currency_code,
          :taxonomies_for_nav,
          :recommended_products,
          :recommended_wishlists,
          :curated_product_ids,
          :search_offset
        )
      end

      it "uses the user's currency code when logged in" do
        @buyer.update!(currency_type: "eur")

        get :index

        expect(inertia.props[:currency_code]).to eq("eur")
      end

      it "falls back to usd currency code when not logged in" do
        sign_out @buyer

        get :index

        expect(inertia.props[:currency_code]).to eq("usd")
      end

      it "includes search_offset from params" do
        get :index, params: { from: 10 }

        expect(inertia.props[:search_offset]).to eq("10")
      end
    end

    context "recommended_products" do
      it "returns empty array when offer_code is present" do
        get :index, params: { offer_code: "SALE10" }

        expect(inertia.props[:recommended_products]).to eq([])
      end

      it "returns recommended products when taxonomy is present" do
        taxonomy = Taxonomy.create!(slug: "test-3d")
        taxonomy_product = create(:product, taxonomy:)
        child_taxonomy_product = create(:product, taxonomy:)

        # Stub search_products to return our test products when taxonomy is present
        allow_any_instance_of(DiscoverController).to receive(:search_products).and_wrap_original do |method, params|
          if params[:taxonomy_id] == taxonomy.id && params[:size] == DiscoverController::RECOMMENDED_PRODUCTS_COUNT
            # For recommendations call
            { products: Link.where(id: [taxonomy_product.id, child_taxonomy_product.id]), total: 2 }
          else
            # For main search results
            { products: Link.none, total: 0 }
          end
        end

        get :index, params: { taxonomy: "test-3d" }

        recommended_product_ids = inertia.props[:recommended_products].pluck(:id)
        expect(recommended_product_ids).to include(taxonomy_product.external_id, child_taxonomy_product.external_id)
      end

      it "returns curated products when available" do
        cart = create(:cart, user: @buyer)
        create(:cart_product, cart:, product: @product)
        recommended_product = create(:product)

        expect(RecommendedProducts::DiscoverService).to receive(:fetch).with(
          purchaser: @buyer,
          cart_product_ids: [@product.id],
          recommender_model_name: RecommendedProductsService::MODEL_SALES,
        ).and_return([RecommendedProducts::ProductInfo.new(recommended_product)])

        get :index

        expect(inertia.props[:recommended_products]).to be_present
        expect(inertia.props[:recommended_products].first[:id]).to eq(recommended_product.external_id)
      end
    end

    context "recommended_wishlists" do
      let(:wishlists) { Wishlist.where(id: create_list(:wishlist, 4).map(&:id)) }

      it "fetches recommended wishlists with correct parameters" do
        cart = create(:cart, user: @buyer)
        create(:cart_product, cart:, product: @product)
        recommended_product = create(:product)

        allow(RecommendedProducts::DiscoverService).to receive(:fetch).and_return(
          [RecommendedProducts::ProductInfo.new(recommended_product)]
        )

        expect(RecommendedWishlistsService).to receive(:fetch).with(
          limit: 4,
          current_seller: @buyer,
          curated_product_ids: [],
          taxonomy_id: nil
        ).and_return(wishlists)

        get :index

        expect(inertia.props[:recommended_wishlists]).to be_present
      end

      it "fetches wishlists with taxonomy_id when taxonomy is present" do
        taxonomy = Taxonomy.create!(slug: "test-taxonomy")
        taxonomy_product = create(:product, taxonomy:)

        # Stub search_products to return products for taxonomy-based recommendations
        allow_any_instance_of(DiscoverController).to receive(:search_products).and_wrap_original do |method, params|
          if params[:taxonomy_id] == taxonomy.id && params[:size] == DiscoverController::RECOMMENDED_PRODUCTS_COUNT
            { products: Link.where(id: taxonomy_product.id), total: 1 }
          else
            { products: Link.none, total: 0 }
          end
        end

        expect(RecommendedWishlistsService).to receive(:fetch).with(
          limit: 4,
          current_seller: @buyer,
          curated_product_ids: [],
          taxonomy_id: taxonomy.id
        ).and_return(wishlists)

        get :index, params: { taxonomy: "test-taxonomy" }

        expect(inertia.props[:recommended_wishlists]).to be_present
      end

      it "passes curated_product_ids from excess curated products to wishlist service" do
        cart = create(:cart, user: @buyer)
        create(:cart_product, cart:, product: @product)

        # Create 10 recommended products (more than RECOMMENDED_PRODUCTS_COUNT = 8)
        recommended_products = create_list(:product, 10)
        product_infos = recommended_products.map { |p| RecommendedProducts::ProductInfo.new(p) }

        allow(RecommendedProducts::DiscoverService).to receive(:fetch).and_return(product_infos)

        # The excess product IDs (products 9 and 10) should be passed to wishlist service
        excess_product_ids = recommended_products[8..].map(&:id)

        expect(RecommendedWishlistsService).to receive(:fetch).with(
          limit: 4,
          current_seller: @buyer,
          curated_product_ids: excess_product_ids,
          taxonomy_id: nil
        ).and_return(wishlists)

        get :index
      end

      it "returns empty array when offer_code is present" do
        get :index, params: { offer_code: "SALE10" }

        expect(inertia.props[:recommended_wishlists]).to eq([])
      end

      it "returns empty array when query is present" do
        cart = create(:cart, user: @buyer)
        create(:cart_product, cart:, product: @product)
        recommended_product = create(:product)

        allow(RecommendedProducts::DiscoverService).to receive(:fetch).and_return(
          [RecommendedProducts::ProductInfo.new(recommended_product)]
        )

        get :index, params: { query: "test" }

        expect(inertia.props[:recommended_wishlists]).to eq([])
      end

      it "returns empty array when there are no recommended products" do
        allow(RecommendedProducts::DiscoverService).to receive(:fetch).and_return([])

        get :index

        expect(inertia.props[:recommended_wishlists]).to eq([])
      end
    end
  end
end
