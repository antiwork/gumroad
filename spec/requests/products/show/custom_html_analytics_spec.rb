# frozen_string_literal: true

require "spec_helper"

# A custom HTML landing page renders as a bare wrapper document that embeds the
# seller's HTML in a sandboxed, opaque-origin iframe. That bypasses the React
# product page which normally records Gumroad's internal view count and fires the
# seller's analytics, so the trusted wrapper has to own both jobs.
describe "Custom HTML landing page analytics", type: :request do
  let(:seller) { create(:user, username: "analyticsseller", google_analytics_id: "G-ABC123") }
  let(:product) { create(:product, user: seller, custom_html: "<main><h1>Custom landing</h1></main>") }

  before do
    Feature.activate_user(:custom_html_pages, seller)
    # analytics_enabled? only tracks in production/staging, matching the rest of the app.
    allow(Rails.env).to receive(:production?).and_return(true)
    # Resolving the Vite manifest for a real build is infra, not what we're testing —
    # assert the entry point is requested by name and stub the tag it renders.
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag)
      .with("custom_html_analytics").and_return(%(<script src="/custom_html_analytics.js"></script>).html_safe)
  end

  # Request the canonical subdomain URL directly: in production mode the apex
  # /l/:permalink 302-redirects to the seller's subdomain, which would swallow
  # the rendered body.
  def get_wrapper
    get product.long_url
  end

  def analytics_props(body)
    content = body[/<meta name="gr:custom-html-analytics" content="([^"]*)"/, 1]
    content && JSON.parse(CGI.unescapeHTML(content))
  end

  it "injects the enabled meta tags, seller props, and analytics entry point into the wrapper head" do
    get_wrapper

    expect(response).to be_successful
    expect(response.body).to include('<meta property="gr:google_analytics:enabled" content="true">')
    expect(response.body).to include('<meta property="gr:fb_pixel:enabled" content="true">')
    expect(response.body).to include('<meta property="gr:tiktok_pixel:enabled" content="true">')
    expect(response.body).to include('<meta name="csrf-token"')
    expect(response.body).to include('src="/custom_html_analytics.js"')

    props = analytics_props(response.body)
    expect(props).to include(
      "seller_id" => seller.external_id,
      "permalink" => product.unique_permalink,
      "name" => product.name,
      "third_party_analytics_domain" => THIRD_PARTY_ANALYTICS_DOMAIN,
      "tracking_enabled" => true,
      "has_product_third_party_analytics" => false,
    )
    expect(props["analytics"]).to include("google_analytics_id" => "G-ABC123")
  end

  it "does not inject analytics into the sandboxed landing iframe, whose CSP would block them" do
    get "#{product.long_url}/landing/embed"

    expect(response.body).not_to include("gr:custom-html-analytics")
    expect(response.body).not_to include("gr:google_analytics:enabled")
  end

  context "when the seller has no analytics configured" do
    let(:seller) { create(:user, username: "noanalyticsseller") }

    it "still loads the entry point so Gumroad's internal view counter fires" do
      get_wrapper

      expect(response.body).to include("gr:custom-html-analytics")
      expect(response.body).to include('src="/custom_html_analytics.js"')
      expect(response.body).not_to include("gr:google_analytics:enabled")

      props = analytics_props(response.body)
      expect(props).to include(
        "tracking_enabled" => true,
        "has_product_third_party_analytics" => false,
        "permalink" => product.unique_permalink,
      )
    end
  end

  context "when the seller disabled third-party analytics" do
    before { seller.update!(disable_third_party_analytics: true) }

    it "still loads the entry point with third-party tracking disabled and no pixel ids in the source" do
      get_wrapper

      expect(response.body).to include("gr:custom-html-analytics")
      expect(response.body).to include('src="/custom_html_analytics.js"')
      expect(response.body).not_to include("gr:google_analytics:enabled")
      # The seller has a configured Google Analytics id, but with tracking
      # disabled it must not be visible anywhere in the page source.
      expect(response.body).not_to include("G-ABC123")

      props = analytics_props(response.body)
      expect(props).to include(
        "tracking_enabled" => false,
        "has_product_third_party_analytics" => false,
        "permalink" => product.unique_permalink,
      )
      expect(props["analytics"]).to include(
        "google_analytics_id" => nil,
        "facebook_pixel_id" => nil,
        "tiktok_pixel_id" => nil,
      )
    end
  end

  context "when the seller has only a raw third-party analytics snippet (no pixel ids)" do
    let(:seller) { create(:user, username: "snippetseller") }

    before { ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "product") }

    it "injects the block so the entry point loads the snippet iframe" do
      get_wrapper

      props = analytics_props(response.body)
      expect(props["has_product_third_party_analytics"]).to eq(true)
    end
  end
end
