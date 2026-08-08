# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe DiscoverController, type: :controller, inertia: true do
  let(:discover_domain_with_protocol) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @product = create(:product, user: create(:user, name: "Gumstein"))
    sign_in @buyer
  end

  describe "#index" do
    it "renders the Discover Inertia page with recommendation props" do
      get :index

      expect(response).to be_successful
      expect_inertia.to render_component("Discover/Index")
      expect(inertia.props).to include(
        :currency_code,
        :search_results,
        :taxonomies_for_nav,
        :curated_product_ids,
        :show_black_friday_hero,
        :is_black_friday_page,
        :black_friday_offer_code,
        :black_friday_stats,
      )
      expect(inertia.props[:currency_code]).to eq(@buyer.currency_type)

      expect(inertia.props[:search_results]).to include(:products, :total, :tags_data, :filetypes_data)
      expect(inertia.props[:search_results][:products]).to be_an(Array)
      expect(inertia.props[:search_results][:total]).to be_a(Integer)

      expect(inertia.props[:taxonomies_for_nav]).to be_an(Array)
      if inertia.props[:taxonomies_for_nav].any?
        expect(inertia.props[:taxonomies_for_nav].first).to include(:slug, :label)
      end

      expect(inertia.props[:curated_product_ids]).to be_an(Array)
      expect(inertia.props[:curated_product_ids]).to all(be_a(String))
      expect(inertia.props[:show_black_friday_hero]).to be_in([true, false])
      expect(inertia.props[:is_black_friday_page]).to eq(false)
      expect(inertia.props[:black_friday_offer_code]).to eq(SearchProducts::BLACK_FRIDAY_CODE)
      expect(inertia.props[:black_friday_stats]).to satisfy { |value| value.nil? || value.is_a?(Hash) }
      expect(inertia.props).not_to have_key(:recommended_products)
      expect(inertia.props).not_to have_key(:recommended_wishlists)
    end

    it "sets black friday page props when offer code is provided" do
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(:offer_codes_search).and_return(true)

      get :index, params: { offer_code: SearchProducts::BLACK_FRIDAY_CODE }

      expect(response).to be_successful
      expect_inertia.to render_component("Discover/Index")
      expect(inertia.props[:is_black_friday_page]).to eq(true)
      expect(inertia.props[:black_friday_offer_code]).to eq(SearchProducts::BLACK_FRIDAY_CODE)
    end

    context "nav first render" do
      it "renders discover inertia payload for iPhone user-agent" do
        @request.user_agent = "Mozilla/5.0 (iPhone; CPU OS 13_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.2 Mobile/15E148 Safari/604.1"

        get :index

        expect(response).to be_successful
        expect_inertia.to render_component("Discover/Index")
        expect(inertia.props[:taxonomies_for_nav]).to be_an(Array)
      end

      it "renders discover inertia payload for desktop user-agent" do
        @request.user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36."

        get :index

        expect(response).to be_successful
        expect_inertia.to render_component("Discover/Index")
        expect(inertia.props[:taxonomies_for_nav]).to be_an(Array)
      end
    end

    context "when fetching recommendation props via inertia partial data" do
      before do
        request.headers["X-Inertia"] = "true"
        request.headers["X-Inertia-Partial-Component"] = "Discover/Index"
      end

      it "returns recommended products in partial props" do
        request.headers["X-Inertia-Partial-Data"] = "recommended_products"

        get :index

        expect(response).to be_successful
        props = response.parsed_body.fetch("props")
        expect(props["recommended_products"]).to be_an(Array)
        expect(props).not_to have_key("search_results")
      end

      it "returns recommended wishlists in partial props" do
        request.headers["X-Inertia-Partial-Data"] = "recommended_wishlists"

        get :index

        expect(response).to be_successful
        props = response.parsed_body.fetch("props")
        expect(props["recommended_wishlists"]).to be_an(Array)
        expect(props).not_to have_key("search_results")
      end

      it "only fetches search_results when filtering without taxonomy change" do
        request.headers["X-Inertia-Partial-Data"] = "search_results"

        get :index, params: { query: "test", tags: "design" }

        expect(response).to be_successful
        props = response.parsed_body.fetch("props")
        expect(props["search_results"]).to be_present
        expect(props["search_results"]["products"]).to be_an(Array)
        expect(props).not_to have_key("recommended_products")
        expect(props).not_to have_key("recommended_wishlists")
      end

      describe "recently_viewed partial props" do
        before do
          request.headers["X-Inertia-Partial-Data"] = "recently_viewed"
        end

        it "returns nil when the feature flag is off" do
          get :index

          expect(response).to be_successful
          expect(response.parsed_body.fetch("props")["recently_viewed"]).to be_nil
        end

        it "returns the visitor's recently viewed products when the flag is on" do
          Feature.activate(:discover_recently_viewed)
          user = create(:user)
          sign_in user
          product = create(:product, :recommendable, name: "Seen Before")
          Link.import(force: true, refresh: true)
          add_page_view(product, 1.day.ago.iso8601, user_id: user.id)
          ProductPageView.__elasticsearch__.refresh_index!

          get :index

          expect(response).to be_successful
          data = response.parsed_body.fetch("props").fetch("recently_viewed")
          expect(data["products"].map { _1["name"] }).to eq(["Seen Before"])
          expect(data["products"].first["url"]).to include("recommended_by=recently_viewed")
        ensure
          Feature.deactivate(:discover_recently_viewed)
        end

        it "returns nil when an offer code is present" do
          Feature.activate(:discover_recently_viewed)

          get :index, params: { offer_code: SearchProducts::BLACK_FRIDAY_CODE }

          expect(response).to be_successful
          expect(response.parsed_body.fetch("props")["recently_viewed"]).to be_nil
        ensure
          Feature.deactivate(:discover_recently_viewed)
        end

        it "reaches anonymous visitors through a browser-guid actor under a percentage gate" do
          sign_out @buyer
          Feature.activate_percentage(:discover_recently_viewed, 100)
          browser_guid = SecureRandom.uuid
          cookies[:_gumroad_guid] = browser_guid
          product = create(:product, :recommendable, name: "Seen Anonymously")
          Link.import(force: true, refresh: true)
          add_page_view(product, 1.day.ago.iso8601, browser_guid:)
          ProductPageView.__elasticsearch__.refresh_index!

          get :index

          expect(response).to be_successful
          data = response.parsed_body.fetch("props").fetch("recently_viewed")
          expect(data["products"].map { _1["name"] }).to eq(["Seen Anonymously"])
        ensure
          Feature.deactivate_percentage(:discover_recently_viewed)
        end

        it "hides the row for a control-arm visitor and logs their exposure" do
          sign_out @buyer
          Feature.activate_percentage(:discover_recently_viewed, 50)
          control_guid = Array.new(200) { SecureRandom.uuid }.find do |guid|
            !Flipper.enabled?(:discover_recently_viewed, Flipper::Actor.new("browser_guid:#{guid}"))
          end
          raise "no control guid found in 200 draws" if control_guid.nil?

          cookies[:_gumroad_guid] = control_guid
          product = create(:product, :recommendable)
          Link.import(force: true, refresh: true)
          add_page_view(product, 1.day.ago.iso8601, browser_guid: control_guid)
          ProductPageView.__elasticsearch__.refresh_index!

          logged_lines = []
          allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
            logged_lines << args.first if args.first.is_a?(String)
            original.call(*args, &block)
          end

          get :index

          expect(response).to be_successful
          expect(response.parsed_body.fetch("props")["recently_viewed"]).to be_nil

          exposure = logged_lines.filter_map { |line| JSON.parse(line) rescue nil }
            .find { _1["event"] == "discover_recently_viewed_exposure" }
          expect(exposure).to be_present
          expect(exposure["arm"]).to eq("control")
          expect(exposure["has_history"]).to eq(true)
          expect(exposure["browser_guid_hash"]).to eq(Discover::RecentlyViewedPresenter.anonymous_key(control_guid))
          expect(exposure.values.join).not_to include(control_guid)
        ensure
          Feature.deactivate_percentage(:discover_recently_viewed)
        end

        it "treats an actor-only enable as a plain flag: no lookup and no exposure log for other visitors" do
          qa_user = create(:user)
          Feature.activate_user(:discover_recently_viewed, qa_user)

          expect(Discover::RecentlyViewedPresenter).not_to receive(:new)
          expect(Rails.logger).not_to receive(:info).with(a_string_including("discover_recently_viewed_exposure"))

          get :index

          expect(response).to be_successful
          expect(response.parsed_body.fetch("props")["recently_viewed"]).to be_nil
        ensure
          Feature.deactivate_user(:discover_recently_viewed, qa_user)
        end

        it "does not log exposure when the flag is fully on" do
          Feature.activate(:discover_recently_viewed)
          cookies[:_gumroad_guid] = SecureRandom.uuid

          expect(Rails.logger).not_to receive(:info).with(a_string_including("discover_recently_viewed_exposure"))

          get :index

          expect(response).to be_successful
        ensure
          Feature.deactivate(:discover_recently_viewed)
        end
      end

      context "autocomplete_results partial reload" do
        it "returns autocomplete results with empty query" do
          request.headers["X-Inertia-Partial-Data"] = "autocomplete_results"

          get :index, params: { query: "" }

          expect(response).to be_successful
          props = response.parsed_body.fetch("props")
          expect(props["autocomplete_results"]).to include("products", "recent_searches")
          expect(props["autocomplete_results"]["products"]).to be_an(Array)
          expect(props["autocomplete_results"]["recent_searches"]).to be_an(Array)
          expect(props).not_to have_key("search_results")
          expect(props).not_to have_key("recommended_products")
        end

        it "returns autocomplete results with products matching query" do
          user = create(:recommendable_user, name: "Sample User")
          product = create(:product, :recommendable, name: "Sample Product", user:)
          Link.import(refresh: true, force: true)

          request.headers["X-Inertia-Partial-Data"] = "autocomplete_results"

          get :index, params: { query: "prod" }

          expect(response).to be_successful
          props = response.parsed_body.fetch("props")
          expect(props["autocomplete_results"]["products"][0]).to include(
            "name" => "Sample Product",
            "url" => product.long_url(recommended_by: "search", layout: "discover", autocomplete: true, query: "prod"),
            "seller_name" => "Sample User",
          )
        end

        it "stores the search query as autocomplete" do
          cookies[:_gumroad_guid] = "custom_guid"
          request.headers["X-Inertia-Partial-Data"] = "autocomplete_results"

          expect do
            get :index, params: { query: "prod" }
          end.to change(DiscoverSearch, :count).by(1).and not_change(DiscoverSearchSuggestion, :count)

          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "prod",
            "user_id" => @buyer.id,
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => true
          )
        end

        it "does not store search query when query is blank" do
          request.headers["X-Inertia-Partial-Data"] = "autocomplete_results"

          expect do
            get :index, params: { query: "" }
          end.to not_change(DiscoverSearch, :count).and not_change(DiscoverSearchSuggestion, :count)
        end

        it "returns recent searches based on browser_guid" do
          sign_out @buyer
          cookies[:_gumroad_guid] = "custom_guid"
          create(:discover_search_suggestion, discover_search: create(:discover_search, browser_guid: "custom_guid", query: "recent search"))

          request.headers["X-Inertia-Partial-Data"] = "autocomplete_results"

          get :index, params: { query: "" }

          expect(response).to be_successful
          props = response.parsed_body.fetch("props")
          expect(props["autocomplete_results"]["recent_searches"]).to eq(["recent search"])
        end

        it "returns recent searches for logged in user" do
          create(:discover_search_suggestion, discover_search: create(:discover_search, user: @buyer, query: "user search"))

          request.headers["X-Inertia-Partial-Data"] = "autocomplete_results"

          get :index, params: { query: "" }

          expect(response).to be_successful
          props = response.parsed_body.fetch("props")
          expect(props["autocomplete_results"]["recent_searches"]).to eq(["user search"])
        end
      end
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

    context "when curated products fetch times out" do
      it "renders the page with empty curated products" do
        allow(RecommendedProducts::DiscoverService).to receive(:fetch).and_raise(Timeout::Error)

        get :index

        expect(response).to be_successful
        expect_inertia.to render_component("Discover/Index")
        expect(inertia.props[:curated_product_ids]).to eq([])
      end
    end

    context "when curated products fetch raises an error" do
      it "renders the page with empty curated products" do
        allow(RecommendedProducts::DiscoverService).to receive(:fetch).and_raise(StandardError, "connection lost")

        get :index

        expect(response).to be_successful
        expect_inertia.to render_component("Discover/Index")
        expect(inertia.props[:curated_product_ids]).to eq([])
      end
    end

    context "server-rendered crawl links" do
      render_views

      it "renders top-level category links in the initial HTML of /discover" do
        get :index

        expect(response.body).to include(%(href="#{UrlService.discover_domain_with_protocol}/3d"))
      end

      it "renders subcategory links and pagination hrefs on category pages" do
        # The canonical (no `from` param) request has params[:from] mutated to
        # RECOMMENDED_PRODUCTS_COUNT + 1 to skip the recommendations-strip products, so the
        # real ES offset is 9 — seed past that plus INITIAL_PRODUCTS_COUNT for a genuine next page.
        create_list(:product, DiscoverController::RECOMMENDED_PRODUCTS_COUNT + 3, :recommendable, taxonomy: Taxonomy.find_by(slug: "3d"))
        Link.import(refresh: true, force: true)
        stub_const("DiscoverController::INITIAL_PRODUCTS_COUNT", 1)

        get :index, params: { taxonomy: "3d" }

        expect(response.body).to include(%(href="#{UrlService.discover_domain_with_protocol}/3d/3d-assets"))
        expect(response.body).to include(%(href="#{UrlService.discover_domain_with_protocol}/3d?from=10"))
        expect(response.body).not_to include("Previous page")
      end

      it "links Previous back to the bare category page when the previous page is the first" do
        create_list(:product, DiscoverController::RECOMMENDED_PRODUCTS_COUNT + 4, :recommendable, taxonomy: Taxonomy.find_by(slug: "3d"))
        Link.import(refresh: true, force: true)
        stub_const("DiscoverController::INITIAL_PRODUCTS_COUNT", 1)

        # The bare page serves offset 9 (from mutated to RECOMMENDED_PRODUCTS_COUNT + 1) and
        # links Next to from=10, so from=10 must continue from there without overlap.
        get :index, params: { taxonomy: "3d", from: "10" }

        expect(response.body).to include(%(>Previous page</a>))
        expect(response.body).to include(%(href="#{UrlService.discover_domain_with_protocol}/3d">Previous page))
        expect(response.body).to include(%(href="#{UrlService.discover_domain_with_protocol}/3d?from=11"))
      end

      it "stops emitting Next once the requested offset is past what Elasticsearch can serve" do
        create_list(:product, DiscoverController::RECOMMENDED_PRODUCTS_COUNT + 20, :recommendable, taxonomy: Taxonomy.find_by(slug: "3d"))
        Link.import(refresh: true, force: true)
        stub_const("DiscoverController::INITIAL_PRODUCTS_COUNT", 1)
        stub_const("Link::MAX_RESULT_WINDOW", 10)

        # from=100 is well past MAX_RESULT_WINDOW (10); search_options clamps it to the same
        # terminal ES offset as from=10, so both requests must serve identical results with no
        # further Next link — otherwise a crawler can walk an unbounded chain of distinct URLs.
        get :index, params: { taxonomy: "3d", from: "100" }
        far_body = response.body

        get :index, params: { taxonomy: "3d", from: "10" }
        terminal_body = response.body

        expect(far_body).not_to include("Next page")
        expect(terminal_body).not_to include("Next page")
      end
    end

    context "meta tags" do
      let(:default_description) { "Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs." }

      def meta_tags
        controller.send(:meta_tags)
      end

      it "sets the proper meta tags with no extra parameters" do
        get :index

        expect(meta_tags["meta-property-og-type"][:content]).to eq("website")
        expect(meta_tags["meta-property-og-description"][:content]).to eq(default_description)
        expect(meta_tags["meta-name-description"][:content]).to eq(default_description)
        expect(meta_tags["canonical"][:href]).to eq("#{discover_domain_with_protocol}/")
      end

      it "sets the proper meta tags when a search query was submitted" do
        get :index, params: { query: "tests" }

        expect(meta_tags["title"][:inner_content]).to eq("Search results for \"tests\" | Gumroad")
        expect(meta_tags["meta-property-og-description"][:content]).to eq(default_description)
        expect(meta_tags["meta-name-description"][:content]).to eq(default_description)
        expect(meta_tags["canonical"][:href]).to eq("#{discover_domain_with_protocol}/?query=tests")
      end

      it "sets the SEO title and description when only taxonomy is present" do
        get :index, params: { taxonomy: "software-development/programming/c-sharp" }

        expect(meta_tags["title"][:inner_content]).to eq("Software Development » Programming » C# — digital products by independent creators | Gumroad")
        expect(meta_tags["meta-name-description"][:content]).to include("C# products from independent creators on Gumroad")
      end

      it "renders BreadcrumbList and ItemList JSON-LD for category pages" do
        # index skips the first RECOMMENDED_PRODUCTS_COUNT results (shown via the
        # recommendations strip), so seed past that for a non-empty ItemList.
        create_list(:product, DiscoverController::RECOMMENDED_PRODUCTS_COUNT + 2, :recommendable, taxonomy: Taxonomy.find_by(slug: "3d"))
        Link.import(refresh: true, force: true)

        get :index, params: { taxonomy: "3d" }

        breadcrumbs = meta_tags["breadcrumb-list-json-ld"][:inner_content]
        expect(breadcrumbs["@type"]).to eq("BreadcrumbList")
        expect(breadcrumbs["itemListElement"].first).to include(
          "position" => 1,
          "name" => "Discover",
        )
        expect(breadcrumbs["itemListElement"].last["item"]).to eq("#{discover_domain_with_protocol}/3d")

        item_list = meta_tags["item-list-json-ld"][:inner_content]
        expect(item_list["@type"]).to eq("ItemList")
        product_item = item_list["itemListElement"].first["item"]
        expect(product_item["@type"]).to eq("Product")
        expect(product_item["name"]).to be_present
        expect(product_item["url"]).to be_present
        expect(product_item["offers"]).to include("@type" => "Offer", "priceCurrency" => "USD")
      end

      it "does not render category JSON-LD when a query or tags are present" do
        get :index, params: { taxonomy: "3d", query: "dragons" }

        expect(meta_tags["breadcrumb-list-json-ld"]).to be_nil
        expect(meta_tags["item-list-json-ld"]).to be_nil
      end

      it "sets the proper title when tags and taxonomy are present" do
        get :index, params: { tags: "some-tag", taxonomy: "software-development/programming/c-sharp" }

        expect(meta_tags["title"][:inner_content]).to eq("some tag | Software Development » Programming » C# | Gumroad")
      end

      it "sets the proper title when tags are sent as nested hash params alongside taxonomy" do
        get :index, params: { tags: { "0" => "some-tag" }, taxonomy: "software-development/programming/c-sharp" }

        expect(response).to have_http_status(:ok)
        expect(meta_tags["title"][:inner_content]).to eq("some tag | Software Development » Programming » C# | Gumroad")
      end

      it "sets the proper meta tags when a specific tag has been selected" do
        get :index, params: { tags: "3d models" }

        description = "Browse over 0 3D assets including 3D models, CG textures, HDRI environments & more" \
                      " for VFX, game development, AR/VR, architecture, and animation."
        expect(meta_tags["title"][:inner_content]).to eq("Professional 3D Modeling Assets | Gumroad")
        expect(meta_tags["meta-property-og-description"][:content]).to eq(description)
        expect(meta_tags["meta-name-description"][:content]).to eq(description)
        expect(meta_tags["canonical"][:href]).to eq("#{discover_domain_with_protocol}/?tags=3d+models")
      end

      it "sets the proper meta tags when a specific tag has been selected with different formatting" do
        get :index, params: { tags: "3d      - mODELs" }

        description = "Browse over 0 3D assets including 3D models, CG textures, HDRI environments & more" \
                      " for VFX, game development, AR/VR, architecture, and animation."
        expect(meta_tags["title"][:inner_content]).to eq("Professional 3D Modeling Assets | Gumroad")
        expect(meta_tags["meta-property-og-description"][:content]).to eq(description)
        expect(meta_tags["meta-name-description"][:content]).to eq(description)
        expect(meta_tags["canonical"][:href]).to eq("#{discover_domain_with_protocol}/?tags=3d+models")
      end

      context "meta description total count" do
        let(:total_products) { Link::RECOMMENDED_PRODUCTS_PER_PAGE + 2 }

        before do
          total_products.times do
            product = create(:product, :recommendable)
            product.tag!("3d models")
          end
          Link.import(refresh: true, force: true)
        end

        it "sets the correct total search result size in the meta description" do
          get :index, params: { tags: "3d models" }

          description = "Browse over #{total_products} 3D assets including 3D models, CG textures, HDRI environments & more" \
                        " for VFX, game development, AR/VR, architecture, and animation."
          expect(meta_tags["meta-property-og-description"][:content]).to eq(description)
          expect(meta_tags["meta-name-description"][:content]).to eq(description)
        end
      end
    end
  end
end
