# frozen_string_literal: true

require "spec_helper"

# A custom HTML profile page renders as a bare wrapper document that embeds the
# seller's HTML in a sandboxed, opaque-origin iframe. That bypasses the React
# profile page, so the wrapper has to inject the seller's account-scoped
# analytics itself — the profile counterpart of the custom product landing page
# fix (#5658). These specs verify it does, and only in the trusted wrapper,
# only when the seller has analytics configured and enabled.
describe "Custom HTML profile page analytics", type: :request do
  let(:seller) { create(:user, username: "analyticsprofile", google_analytics_id: "G-ABC123") }
  let!(:custom_domain) { create(:custom_domain, user: seller, domain: "seller.example.com") }

  before do
    seller.update!(custom_html: "<main><h1>Custom profile</h1></main>")
    Feature.activate_user(:custom_html_pages, seller)
    # analytics_enabled? only tracks in production/staging, matching the rest of the app.
    allow(Rails.env).to receive(:production?).and_return(true)
    # Resolving the Vite manifest for a real build is infra, not what we're testing —
    # assert the entry point is requested by name and stub the tag it renders.
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag)
      .with("custom_html_profile_analytics").and_return(%(<script src="/custom_html_profile_analytics.js"></script>).html_safe)
  end

  def analytics_props(body)
    content = body[/<meta name="gr:custom-html-profile-analytics" content="([^"]*)"/, 1]
    content && JSON.parse(CGI.unescapeHTML(content))
  end

  it "injects the enabled meta tags, seller props, and analytics entry point into the wrapper head" do
    get "http://seller.example.com/"

    expect(response).to be_successful
    expect(response.body).to include('<meta property="gr:google_analytics:enabled" content="true">')
    expect(response.body).to include('<meta property="gr:fb_pixel:enabled" content="true">')
    expect(response.body).to include('<meta property="gr:tiktok_pixel:enabled" content="true">')
    expect(response.body).to include('src="/custom_html_profile_analytics.js"')

    props = analytics_props(response.body)
    expect(props).to include(
      "seller_id" => seller.external_id,
      "third_party_analytics_url" => nil,
    )
    expect(props["analytics"]).to include("google_analytics_id" => "G-ABC123")
  end

  it "does not inject analytics into the sandboxed landing iframe, whose CSP would block them" do
    get "http://seller.example.com/landing/embed"

    expect(response).to be_successful
    expect(response.body).not_to include("gr:custom-html-profile-analytics")
    expect(response.body).not_to include("gr:google_analytics:enabled")
  end

  context "when the seller has no analytics configured" do
    let(:seller) { create(:user, username: "noanalytics") }

    it "omits the analytics block so the wrapper stays minimal" do
      get "http://seller.example.com/"

      expect(response).to be_successful
      expect(response.body).not_to include("gr:custom-html-profile-analytics")
      expect(response.body).not_to include("gr:google_analytics:enabled")
    end
  end

  context "when the seller disabled third-party analytics" do
    before { seller.update!(disable_third_party_analytics: true) }

    it "omits the analytics block" do
      get "http://seller.example.com/"

      expect(response.body).not_to include("gr:custom-html-profile-analytics")
    end
  end

  context "when the seller has only a universal run-everywhere snippet (no pixel ids)" do
    let(:seller) { create(:user, username: "snippetprofile") }

    before { ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "all") }

    it "injects the block with the profile snippet URL so the entry point loads the snippet iframe" do
      get "http://seller.example.com/"

      props = analytics_props(response.body)
      expect(props["third_party_analytics_url"]).to eq(
        "http://#{THIRD_PARTY_ANALYTICS_DOMAIN}/profile/#{seller.username}"
      )
    end
  end

  context "when the seller's universal snippets target only product or receipt pages" do
    let(:seller) { create(:user, username: "productsnippet") }

    before { ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "product") }

    it "omits the analytics block — a profile is neither surface" do
      get "http://seller.example.com/"

      expect(response.body).not_to include("gr:custom-html-profile-analytics")
    end
  end
end
