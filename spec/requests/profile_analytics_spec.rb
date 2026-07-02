# frozen_string_literal: true

require "spec_helper"

# Seller GA/pixels never fired on any profile surface: startTrackingForSeller is
# only called from product/checkout/mobile. The standard Inertia profile page
# now receives account-scoped analytics props so the frontend can boot the
# tracking, and the custom HTML profile wrapper re-injects it the same way the
# custom product landing page does — only ever in the trusted wrapper, never in
# the sandboxed opaque-origin iframe.
describe "Profile page analytics", type: :request do
  let(:seller) { create(:user, username: "analyticsseller", google_analytics_id: "G-ABC123") }

  describe "standard (Inertia) profile page" do
    # analytics_enabled? only tracks in production/staging, matching the rest of the app.
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    def seller_analytics_props
      get "#{seller.subdomain_with_protocol}/", headers: { "X-Inertia" => "true" }
      expect(response).to be_successful
      JSON.parse(response.body).dig("props", "seller_analytics")
    end

    it "includes the seller's account-scoped analytics props" do
      expect(seller_analytics_props).to eq(
        "seller_id" => seller.external_id,
        "analytics" => {
          "google_analytics_id" => "G-ABC123",
          "facebook_pixel_id" => nil,
          "tiktok_pixel_id" => nil,
          "free_sales" => true,
        },
        "has_universal_third_party_analytics" => false,
        "username" => "analyticsseller",
      )
    end

    it "flags universal third-party snippets scoped to all pages" do
      ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "all")

      expect(seller_analytics_props["has_universal_third_party_analytics"]).to eq(true)
    end

    it "does not flag snippets scoped to the purchase flow" do
      ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "product")

      expect(seller_analytics_props["has_universal_third_party_analytics"]).to eq(false)
    end

    it "does not flag universal snippets when the seller opted out of third-party analytics" do
      ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "all")
      seller.update!(disable_third_party_analytics: true)

      # The universal-snippets iframe has no shouldTrack() guard, so the opt-out
      # must be honored server-side or the snippet fires on every visitor.
      expect(seller_analytics_props["has_universal_third_party_analytics"]).to eq(false)
    end

    it "does not flag universal snippets outside production/staging" do
      ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "all")
      allow(Rails.env).to receive(:production?).and_return(false)
      allow(Rails.env).to receive(:staging?).and_return(false)

      expect(seller_analytics_props["has_universal_third_party_analytics"]).to eq(false)
    end
  end

  describe "custom HTML profile page" do
    before do
      seller.update!(custom_html: "<main><h1>Custom profile</h1></main>")
      Feature.activate_user(:custom_html_pages, seller)
      # analytics_enabled? only tracks in production/staging, matching the rest of the app.
      allow(Rails.env).to receive(:production?).and_return(true)
      # Resolving the Vite manifest for a real build is infra, not what we're testing —
      # assert the entry point is requested by name and stub the tag it renders.
      allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag)
        .with("custom_html_analytics").and_return(%(<script src="/custom_html_analytics.js"></script>).html_safe)
    end

    def get_wrapper
      get "#{seller.subdomain_with_protocol}/"
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
      expect(response.body).to include('src="/custom_html_analytics.js"')

      props = analytics_props(response.body)
      expect(props).to include(
        "seller_id" => seller.external_id,
        "username" => "analyticsseller",
        "third_party_analytics_domain" => THIRD_PARTY_ANALYTICS_DOMAIN,
        "has_universal_third_party_analytics" => false,
      )
      expect(props["analytics"]).to include("google_analytics_id" => "G-ABC123")
      # The profile payload carries no product fields — their absence routes the
      # shared custom_html_analytics entry point down its page-view-only branch
      # (no product events, no checkout listener).
      expect(props).not_to have_key("permalink")
      expect(props).not_to have_key("name")
    end

    it "does not inject analytics into the sandboxed landing iframe, whose CSP would block them" do
      get "#{seller.subdomain_with_protocol}/landing/embed"

      expect(response.body).not_to include("gr:custom-html-analytics")
      expect(response.body).not_to include("gr:google_analytics:enabled")
    end

    context "when the seller has no analytics configured" do
      let(:seller) { create(:user, username: "noanalytics") }

      it "omits the analytics block so the wrapper stays minimal" do
        get_wrapper

        expect(response.body).not_to include("gr:custom-html-analytics")
        expect(response.body).not_to include("gr:google_analytics:enabled")
      end
    end

    context "when the seller disabled third-party analytics" do
      before { seller.update!(disable_third_party_analytics: true) }

      it "omits the analytics block" do
        get_wrapper

        expect(response.body).not_to include("gr:custom-html-analytics")
      end
    end

    context "when the seller has only a universal raw snippet (no pixel ids)" do
      let(:seller) { create(:user, username: "snippetseller") }

      before { ThirdPartyAnalytic.create!(user: seller, analytics_code: "<script>1</script>", location: "all") }

      it "injects the block so the entry point loads the snippet iframe" do
        get_wrapper

        props = analytics_props(response.body)
        expect(props["has_universal_third_party_analytics"]).to eq(true)
      end
    end
  end
end
