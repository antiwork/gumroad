# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Web build demo", type: :request, inertia: true do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 0) }
  let!(:build) { create(:product_build, :live, product:, number: 1, site_unpacked_at: Time.current) }
  let(:s3) { Aws::S3::Client.new }
  let(:index_html) { %(<!doctype html><html><head><title>Game</title><script src="game.js"></script></head><body></body></html>) }

  before do
    host! DOMAIN
    Feature.activate_user(:product_build_player, seller)
    Feature.activate_user(:product_build_demo, seller)
    s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/index.html", body: index_html, content_type: "text/html")
    s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/game.js", body: "console.log(1)", content_type: "text/javascript")
  end

  after do
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "#{build.site_prefix}/").contents.each do |object|
      s3.delete_object(bucket: S3_BUCKET, key: object.key)
    end
  end

  def demo_path = "/demo/#{product.external_id}"

  def frame_path
    get demo_path
    expect(response).to have_http_status(:ok)
    inertia.props[:frame_url]
  end

  def twitter_meta(name)
    Nokogiri::HTML(response.body).at_css(%(meta[property="#{name}"]))&.[]("content")
  end

  describe "the product page" do
    before { create(:asset_preview, link: product) }

    it "points X at the demo on the app domain, with the poster image" do
      get short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol)

      expect(response).to have_http_status(:ok)
      expect(twitter_meta("twitter:card")).to eq("player")
      expect(twitter_meta("twitter:player")).to eq("#{PROTOCOL}://#{DOMAIN}/demo/#{product.external_id}")
      expect(twitter_meta("twitter:player:width")).to eq("640")
      expect(twitter_meta("twitter:player:height")).to eq("480")
      expect(twitter_meta("twitter:image")).to eq(product.social_share_image)
    end

    it "points X at the demo from a custom HTML product page too" do
      Feature.activate_user(:custom_html_pages, seller)
      product.update!(custom_html: "<section><h1>Play it</h1></section>")

      get short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol)

      expect(response.body).to include("/landing/embed")
      expect(twitter_meta("twitter:card")).to eq("player")
      expect(twitter_meta("twitter:player")).to eq("#{PROTOCOL}://#{DOMAIN}/demo/#{product.external_id}")
      expect(twitter_meta("twitter:player:width")).to eq("640")
    end

    it "keeps the usual card for a paid product" do
      product.update!(price_cents: 500)

      get short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol)

      expect(twitter_meta("twitter:card")).to eq("summary_large_image")
      expect(twitter_meta("twitter:player")).to be_nil
    end

    it "keeps the usual card when the demo flag is off for the seller" do
      Feature.deactivate_user(:product_build_demo, seller)

      get short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol)

      expect(twitter_meta("twitter:card")).to eq("summary_large_image")
    end
  end

  describe "GET /demo/:id" do
    it "renders the build under a demo grant, with a link to the product" do
      path = frame_path

      expect_inertia.to render_component("ProductBuildDemos/Show")
      expect(inertia.props).to include(title: product.name, product_url: "/demo/#{product.external_id}/product")
      expect(path).to match(%r{\A/demo/#{product.external_id}/[^/]+/\z})
      grant = path.split("/")[3]
      expect(ProductBuild.verified_player_grant(grant, url_redirect_token: product.external_id, purpose: ProductBuild::PLAYER_DEMO_GRANT_PURPOSE)).to include(
        "build_id" => build.id, "site_prefix" => build.site_prefix,
      )
      expect(ProductBuild.verified_player_grant(grant, url_redirect_token: product.external_id)).to be_nil
    end

    it "lets X frame it" do
      get demo_path

      # SecureHeaders drops the scheme; on an https page a host source still matches https only.
      expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors 'self' x.com *.x.com twitter.com *.twitter.com")
      expect(response.headers["X-Frame-Options"]).to be_nil
    end

    it "logs each play, so plays from X can be counted" do
      allow(Rails.logger).to receive(:info)

      get demo_path, headers: { "Sec-Fetch-Dest" => "iframe" }

      expect(Rails.logger).to have_received(:info).with(%([ProductBuildDemo] {"event":"show","product_id":#{product.id},"seller_id":#{seller.id},"framed":true}))
    end

    it "returns 404 for a paid product" do
      product.update!(price_cents: 500)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when any version of the product costs money" do
      category = create(:variant_category, link: product)
      create(:variant, variant_category: category, price_difference_cents: 0)
      create(:variant, variant_category: category, price_difference_cents: 300)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a membership" do
      membership = create(:membership_product, user: seller, price_cents: 0)
      create(:product_build, :live, product: membership, number: 1, site_unpacked_at: Time.current)

      get "/demo/#{membership.external_id}"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an unpublished product" do
      product.update!(draft: true)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a banned product" do
      product.update!(banned_at: Time.current)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the seller is suspended" do
      seller.update!(user_risk_state: "suspended_for_tos_violation")

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a preorder, which delivers nothing yet" do
      product.update!(is_in_preorder_state: true)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the demo flag is off for the seller" do
      Feature.deactivate_user(:product_build_demo, seller)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the player's kill switch is off for the seller" do
      Feature.deactivate_user(:product_build_player, seller)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 on a seller's subdomain, which the card must never use" do
      get "#{seller.subdomain_with_protocol}#{demo_path}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /demo/:id/product" do
    it "logs the click and sends the visitor to the product page" do
      allow(Rails.logger).to receive(:info)

      get "#{demo_path}/product"

      expect(response).to redirect_to(product.long_url)
      expect(Rails.logger).to have_received(:info).with(%([ProductBuildDemo] {"event":"product","product_id":#{product.id},"seller_id":#{seller.id},"framed":false}))
    end
  end

  describe "the frame document" do
    it "serves the page sandboxed, framable by X, with no save" do
      get frame_path

      expect(response).to have_http_status(:ok)
      csp = response.headers["Content-Security-Policy"]
      expect(csp).to start_with("sandbox allow-scripts allow-pointer-lock;")
      expect(csp).to include("frame-ancestors #{request.base_url} https://x.com https://*.x.com https://twitter.com https://*.twitter.com")
      config = JSON.parse(JSON.parse(response.body[/(?:const|var) config = JSON\.parse\((".*")\);\n/, 1]))
      expect(config).to include("save" => {}, "saveUrl" => nil)
    end

    it "serves the build's other files under the demo grant, sandboxed and with the type their path names" do
      s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/game.js", body: "console.log(1)", content_type: "text/html")

      get "#{frame_path}game.js"

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("console.log(1)")
      expect(response.media_type).to eq("text/javascript")
      csp = response.headers["Content-Security-Policy"]
      expect(csp).to start_with("sandbox allow-scripts allow-pointer-lock;")
      expect(csp).to include("frame-ancestors #{request.base_url} https://x.com")
    end

    it "stops serving files an hour after the demo page loaded" do
      path = frame_path

      travel ProductBuild::PLAYER_DEMO_GRANT_VALID_FOR + 1.minute do
        get "#{path}game.js"
      end

      expect(response).to have_http_status(:not_found)
    end

    it "stops new page loads once the product is no longer free" do
      path = frame_path
      product.update!(price_cents: 500)

      get path

      expect(response).to have_http_status(:not_found)
    end

    it "does not accept a buyer's grant, and a buyer's route does not accept a demo grant" do
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, link: product, purchase:)
      buyer_grant = build.player_grant(url_redirect_token: product.external_id, purchase_id: purchase.id)
      demo_grant = frame_path.split("/")[3]

      get "#{demo_path}/#{buyer_grant}/game.js"
      expect(response).to have_http_status(:not_found)

      get "/d/#{url_redirect.token}/play/#{demo_grant}/game.js"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a demo build the seller chose" do
    let(:demo_html) { %(<!doctype html><html><head><title>Demo</title></head><body>Demo level</body></html>) }
    let!(:demo) { create(:product_build, product:, number: 2, site_unpacked_at: Time.current, demo_selected_at: Time.current) }

    before do
      s3.put_object(bucket: S3_BUCKET, key: "#{demo.site_prefix}/index.html", body: demo_html, content_type: "text/html")
    end

    after do
      s3.list_objects_v2(bucket: S3_BUCKET, prefix: "#{demo.site_prefix}/").contents.each { s3.delete_object(bucket: S3_BUCKET, key: _1.key) }
    end

    it "plays on a paid product, which has no demo otherwise, while buyers keep the live build" do
      product.update!(price_cents: 500)

      get frame_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Demo level")
      expect(ProductBuild.demo_for(product)).to eq(demo)
    end

    it "points the paid product's X card at the demo" do
      product.update!(price_cents: 500)
      create(:asset_preview, link: product)

      get short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol)

      expect(twitter_meta("twitter:card")).to eq("player")
      expect(twitter_meta("twitter:player")).to eq("#{PROTOCOL}://#{DOMAIN}/demo/#{product.external_id}")
    end

    it "takes the place of a free product's live build" do
      get frame_path

      expect(response.body).to include("Demo level")
    end

    it "stops a running demo of the live build at its next page load" do
      demo.update!(demo_selected_at: nil)
      live_path = frame_path
      demo.select_as_demo!

      get live_path

      expect(response).to have_http_status(:not_found)
    end

    it "is never public once it is what buyers of a paid product get" do
      product.update!(price_cents: 500)
      demo.promote!

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "is not played while its site is not unpacked yet" do
      product.update!(price_cents: 500)
      demo.update!(site_unpacked_at: nil)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "is not played once the seller stops using it, on a paid product" do
      product.update!(price_cents: 500)
      demo.unselect_as_demo!

      get demo_path

      expect(response).to have_http_status(:not_found)
    end

    it "is not played while the product is off sale" do
      product.update!(price_cents: 500, draft: true)

      get demo_path

      expect(response).to have_http_status(:not_found)
    end
  end
end
