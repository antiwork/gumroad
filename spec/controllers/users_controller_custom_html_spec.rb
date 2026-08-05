# frozen_string_literal: true

require "spec_helper"

describe UsersController, :vcr, type: :controller do
  CUSTOM_HTML_CSP = RendersCustomHtmlPages::CUSTOM_HTML_CSP

  let(:seller) { create(:user, name: "Jane Doe", bio: "Maker of things") }

  before do
    @request.host = URI.parse(seller.subdomain_with_protocol).host
    seller.update!(custom_html: "<section><h1>Live profile page</h1></section>")
    Feature.activate_user(:custom_html_pages, seller)
  end

  describe "GET show with custom_html" do
    it "renders a wrapper page with an iframe pointing at the landing endpoint" do
      get :show
      expect(response).to be_successful
      expect(response.body).to include("<title>#{seller.name_or_username}</title>")
      expect(response.body).to include(%(property="og:title"))
      expect(response.body).to include(%(src="/landing/embed"))
      expect(response.body).not_to include("<h1>Live profile page</h1>")
    end

    it "sandboxes the iframe without same-origin or top-navigation" do
      get :show
      expect(response.body).to include(%(sandbox="#{RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX}"))
      expect(response.body).not_to include("allow-same-origin")
      expect(response.body).not_to include("allow-top-navigation")
    end

    it "does not embed a checkout bridge — a profile has no native buy button" do
      get :show
      expect(response.body).not_to include("gumroad:checkout")
      expect(response.body).not_to include("wanted=true")
    end

    it "embeds the gumroad:navigate listener so store links can reach the top-level window" do
      get :show
      expect(response.body).to include("gumroad:navigate")
      expect(response.body).to include("STORE_HOSTNAMES")
    end

    describe "facebook-domain-verification meta tag" do
      before do
        seller.update!(
          enable_verify_domain_third_party_services: true,
          facebook_meta_tag: '<meta name="facebook-domain-verification" content="abc123verifycode" />'
        )
        CustomDomain.create(domain: "fb-verify-wrapper.example.com", user: seller)
        @request.host = "fb-verify-wrapper.example.com"
      end

      it "renders the tag in the hand-built wrapper head on a custom domain" do
        get :show

        expect(response.body).to include(%(src="/landing/embed"))
        expect(response.body).to include(%(<meta name="facebook-domain-verification" content="abc123verifycode">))
      end

      it "does not render the tag when domain verification is disabled" do
        seller.update!(enable_verify_domain_third_party_services: false)

        get :show

        expect(response.body).to include(%(src="/landing/embed"))
        expect(response.body).not_to include(%(name="facebook-domain-verification"))
      end

      it "renders the tag when the saved tag uses single quotes" do
        seller.update!(facebook_meta_tag: "<meta name='facebook-domain-verification' content='abc123verifycode' />")

        get :show

        expect(response.body).to include(%(src="/landing/embed"))
        expect(response.body).to include(%(<meta name="facebook-domain-verification" content="abc123verifycode">))
      end
    end

    it "embeds the trusted products-wrapper listener with the landing products endpoint" do
      get :show
      expect(response.body).to include("data-gumroad-products-wrapper")
      expect(response.body).to include("gumroad:products:result")
      expect(response.body).to include("/landing/products")
    end

    it "falls back to the default profile page when custom_html is blank" do
      seller.update!(custom_html: nil)

      get :show

      expect(response.body).not_to include(%(src="/landing/embed"))
      expect(response).to be_successful
    end

    it "answers the JSON profile payload, not the custom-HTML wrapper" do
      get :show, format: :json

      expect(response).to be_successful
      expect(response.body).not_to include(%(src="/landing/embed"))
      expect(response.media_type).to eq("application/json")
    end
  end

  describe "GET landing_iframe_content" do
    it "renders the seller's HTML inside a chromeless document" do
      get :landing_iframe_content
      expect(response).to be_successful
      expect(response.body).to include("<h1>Live profile page</h1>")
      expect(response.body).to start_with("<!doctype html>")
    end

    it "sticks to primary before fetching the seller for the landing page HTML" do
      steps = []
      allow(ActiveRecord::Base.connection).to receive(:stick_to_primary!).and_wrap_original do |method, *args|
        steps << :stick_to_primary
        method.call(*args)
      end
      allow(controller).to receive(:set_user_and_custom_domain_config).and_wrap_original do |method, *args|
        steps << :fetch_user
        method.call(*args)
      end

      get :landing_iframe_content

      expect(response).to be_successful
      expect(steps.index(:stick_to_primary)).to be < steps.index(:fetch_user)
    end

    it "applies the strict CSP and iframe-friendly response headers" do
      get :landing_iframe_content
      expect(response.headers["Content-Security-Policy"]).to eq(CUSTOM_HTML_CSP)
      expect(response.headers["Content-Security-Policy"]).to include("sandbox #{RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX}")
      expect(response.headers["Content-Security-Policy"]).not_to include("allow-same-origin")
      expect(response.headers["Content-Security-Policy"]).not_to include("allow-top-navigation")
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
      expect(response.headers["Content-Type"]).to include("text/html")
      expect(response.headers["Content-Type"]).to include("charset=utf-8")
    end

    it "404s when the profile has no custom_html" do
      seller.update!(custom_html: nil)
      get :landing_iframe_content
      expect(response).to have_http_status(:not_found)
    end

    it "interpolates data-gumroad-field markers with live profile values" do
      seller.update!(custom_html: %(<h1 data-gumroad-field="name">placeholder</h1><p data-gumroad-field="bio">x</p>))

      get :landing_iframe_content

      expect(response.body).to include(">#{seller.name_or_username}<")
      expect(response.body).to include(">#{seller.bio}<")
      expect(response.body).not_to include(">placeholder<")
    end

    it "does not embed a checkout bridge in the iframe document" do
      seller.update!(custom_html: %(<a data-gumroad-action="buy" href="/x">Buy</a>))

      get :landing_iframe_content

      expect(response.body).not_to include("gumroad:checkout")
      expect(response.body).not_to include("wanted=true")
    end

    it "embeds the store navigation bridge in the iframe document" do
      get :landing_iframe_content

      expect(response.body).to include("data-gumroad-navigation-bridge")
      expect(response.body).to include("gumroad:navigate")
    end

    it "embeds the products bridge in the iframe document" do
      get :landing_iframe_content

      expect(response.body).to include("data-gumroad-products-bridge")
      expect(response.body).to include("gumroad:products")
    end

    it "resolves the seller by username on the root domain" do
      @request.host = "app.test.gumroad.com"
      get :landing_iframe_content, params: { username: seller.username }
      expect(response).to be_successful
      expect(response.body).to include("<h1>Live profile page</h1>")
    end

    describe "name/bio live-update listener on ?preview" do
      it "injects the listener for the seller previewing their own page" do
        sign_in seller

        get :landing_iframe_content, params: { preview: true }

        expect(response.body).to include("gumroad:profile-fields")
      end

      it "injects the listener for a team member acting as the seller" do
        member = create(:user)
        create(:team_membership, user: member, seller:, role: TeamMembership::ROLE_ADMIN)
        cookies.encrypted[:current_seller_id] = seller.id
        sign_in member

        get :landing_iframe_content, params: { preview: true }

        expect(response.body).to include("gumroad:profile-fields")
      end

      it "omits the listener for a signed-in visitor who can't edit the profile" do
        sign_in create(:user)

        get :landing_iframe_content, params: { preview: true }

        expect(response.body).not_to include("gumroad:profile-fields")
      end

      it "omits the listener without the preview param" do
        sign_in seller

        get :landing_iframe_content

        expect(response.body).not_to include("gumroad:profile-fields")
      end
    end
  end

  describe "GET landing_products" do
    def create_products(count)
      # Deterministic distinct created_at values so ordering assertions can't flake on ties.
      count.times.map do |i|
        create(:product, user: seller, name: "Product #{i}", created_at: Time.utc(2026, 1, 1) + i.minutes)
      end
    end

    it "returns the requested slice with the catalogue total, newest first" do
      products = create_products(5)

      get :landing_products, params: { offset: 2, limit: 2 }

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["offset"]).to eq(2)
      expect(body["limit"]).to eq(2)
      expect(body["products_total"]).to eq(5)
      expect(body["products"].map { |p| p["name"] }).to eq([products[2].name, products[1].name])
    end

    it "slices in the same order as the injected page 1 payload" do
      create_products(4)

      page_one = Pages::ProfileData.build(seller.reload)[:products].map { |p| p[:name] }
      get :landing_products, params: { offset: 2, limit: 2 }

      expect(response.parsed_body["products"].map { |p| p["name"] }).to eq(page_one[2..3])
    end

    it "slices the prices payload in lockstep when the page references prices" do
      seller.update!(custom_html: %(<div id="app"></div><script>document.getElementById("gumroad-prices")</script>))
      products = create_products(3)

      get :landing_products, params: { offset: 1, limit: 1 }

      prices = response.parsed_body["prices"]
      expect(prices.keys).to eq([products[1].general_permalink])
    end

    it "omits the prices build for pages that reference no price" do
      create_products(1)
      expect(Pages::ProductPrices).not_to receive(:build)

      get :landing_products, params: { offset: 0, limit: 1 }

      expect(response.parsed_body["prices"]).to eq({})
    end

    it "clamps the limit to MAX_ITEMS" do
      create_products(1)

      get :landing_products, params: { offset: 0, limit: 5000 }

      expect(response.parsed_body["limit"]).to eq(Pages::ProfileData::MAX_ITEMS)
    end

    it "rejects a non-integer or negative offset/limit" do
      aggregate_failures do
        [{ offset: -1, limit: 10 }, { offset: "abc", limit: 10 }, { offset: 0, limit: 0 },
         { offset: 0, limit: "abc" }, { offset: 1.5, limit: 10 }, { limit: 10 }, { offset: 0 }].each do |bad_params|
          get :landing_products, params: bad_params
          expect(response).to have_http_status(:bad_request), "expected 400 for #{bad_params.inspect}"
          expect(response.parsed_body["success"]).to be(false)
        end
      end
    end

    it "rejects an offset past the end of the catalogue, so a huge one cannot page the table" do
      create_products(2)

      aggregate_failures do
        # The last valid page starts at the total: it is legitimately empty, and a page asking for
        # it is how a client confirms it has read everything.
        get :landing_products, params: { offset: 2, limit: 2 }
        expect(response).to have_http_status(:ok)

        [3, 10_000, 10**12].each do |offset|
          get :landing_products, params: { offset:, limit: 2 }
          expect(response).to have_http_status(:bad_request), "expected 400 for offset #{offset}"
          expect(response.parsed_body["success"]).to be(false)
        end
      end
    end

    it "is never cacheable by shared caches — the prices half derives from the visitor's IP" do
      seller.update!(custom_html: %(<div data-gumroad-product="x"></div>))
      create_products(1)

      get :landing_products, params: { offset: 0, limit: 1 }

      expect(response.headers["Cache-Control"]).to include("private")
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "404s when the profile has no custom_html" do
      seller.update!(custom_html: nil)

      get :landing_products, params: { offset: 0, limit: 1 }

      expect(response).to have_http_status(:not_found)
    end

    # A slice served by a lagging replica can disagree with the first page the wrapper just
    # rendered, so this pins to primary before the seller lookup like the embed does.
    it "sticks to primary before fetching the seller" do
      steps = []
      allow(ActiveRecord::Base.connection).to receive(:stick_to_primary!).and_wrap_original do |method, *args|
        steps << :stick_to_primary
        method.call(*args)
      end
      allow(controller).to receive(:set_user_and_custom_domain_config).and_wrap_original do |method, *args|
        steps << :fetch_user
        method.call(*args)
      end

      get :landing_products, params: { offset: 0, limit: 1 }

      expect(response).to be_successful
      expect(steps.index(:stick_to_primary)).to be < steps.index(:fetch_user)
    end
  end

  describe "#profile_custom_html_wrapper_document" do
    it "points the iframe at the bare /landing/embed path on a custom/subdomain host" do
      controller.instance_variable_set(:@is_user_custom_domain, true)

      html = controller.send(:profile_custom_html_wrapper_document, seller)

      expect(html).to include(%(src="/landing/embed"))
    end

    it "points the iframe at the /:username/landing/embed path on the root domain" do
      controller.instance_variable_set(:@is_user_custom_domain, false)

      html = controller.send(:profile_custom_html_wrapper_document, seller)

      expect(html).to include(%(src="/#{seller.username}/landing/embed"))
    end

    it "escapes the seller's name for the title attribute" do
      seller.update!(name: %(Jane "</title><script>alert(1)</script>))
      controller.instance_variable_set(:@is_user_custom_domain, true)

      html = controller.send(:profile_custom_html_wrapper_document, seller)

      expect(html).not_to include("<script>alert(1)</script>")
    end
  end

  describe "when the custom_html_pages feature is disabled" do
    before { Feature.deactivate_user(:custom_html_pages, seller) }

    it "renders the default profile page instead of the custom_html wrapper" do
      get :show

      expect(response).to be_successful
      expect(response.body).not_to include(%(src="/landing/embed"))
    end

    it "404s the landing embed endpoint" do
      get :landing_iframe_content

      expect(response).to have_http_status(:not_found)
    end
  end
end
