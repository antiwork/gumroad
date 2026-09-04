# frozen_string_literal: true

require "spec_helper"

# Cheap wiring guard for the gumroad:background bridge. Its behavior is driven
# in a real browser in profile_custom_html_background_spec.rb, but that only
# covers the profile surface — three wrapper/embed pairs carry the fix, and
# dropping either half from any one of them is invisible to a browser spec that
# never visits it. These pin that both halves are present on every surface.
describe "Custom HTML background bridge wiring", type: :request do
  let(:seller) { create(:user, username: "bgwiring", name: "BG Wiring") }
  let(:page_html) { "<section><h1>Landing</h1></section>" }
  let(:host) { seller.subdomain_with_protocol }

  before { Feature.activate_user(:custom_html_pages, seller) }

  # Product wrappers always load custom_html_analytics via vite_typescript_tag.
  # Stub the tag so this wiring guard stays about the background bridge, not Vite.
  before do
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag)
      .with("custom_html_analytics").and_return(%(<script src="/custom_html_analytics.js"></script>).html_safe)
  end

  shared_examples "a surface carrying both halves of the bridge" do
    it "injects the reporter into the sandboxed embed" do
      get "#{host}#{embed_path}"

      expect(response).to be_successful
      expect(response.body).to include("data-gumroad-background-bridge")
      expect(response.body).to include("gumroad:background")
      expect(response.body).to include(RendersCustomHtmlPages::CANVAS_OPAQUE_FN.strip)
    end

    # A retheme through the CSSOM leaves no mutation and no load event, so the
    # periodic re-read is the only thing covering it. Dropping it is silent —
    # every DOM-driven example stays green — so pin that it ships.
    it "injects the periodic re-read into the sandboxed embed" do
      get "#{host}#{embed_path}"

      expect(response.body).to include("}, #{RendersCustomHtmlPages::BACKGROUND_POLL_INTERVAL_MS});")
      expect(response.body).to include("visibilitychange")
    end

    it "injects the listener into the trusted wrapper" do
      get "#{host}#{wrapper_path}"

      expect(response).to be_successful
      expect(response.body).to include("data-gumroad-background-wrapper")
      expect(response.body).to include("theme-color")
      # Both halves answer "is this color opaque?" and must answer it the same
      # way — a wrapper-local copy drifted and painted a transparent
      # oklch(… / 0). Pinning the shared source on both sides is what makes a
      # re-fork fail here rather than in a browser months later.
      expect(response.body).to include(RendersCustomHtmlPages::CANVAS_OPAQUE_FN.strip)
      # Opaque-origin e.origin isn't usable (Chrome reports "null", other
      # engines report the frame URL). Gate on e.source only.
      expect(response.body).not_to include('e.origin !== "null"')
      expect(response.body).to include("e.source !== frame.contentWindow")
    end
  end

  context "the profile storefront" do
    before { seller.update!(custom_html: page_html) }

    let(:wrapper_path) { "/" }
    let(:embed_path) { "/landing/embed" }

    it_behaves_like "a surface carrying both halves of the bridge"
  end

  context "a slugged profile page" do
    before { create(:user_page, pageable: seller, slug: "about", title: "About", custom_html: page_html) }

    let(:wrapper_path) { "/about" }
    let(:embed_path) { "/about/landing/embed" }

    it_behaves_like "a surface carrying both halves of the bridge"
  end

  context "a product landing page" do
    let!(:product) { create(:product, user: seller, custom_html: page_html) }

    let(:wrapper_path) { "/l/#{product.unique_permalink}" }
    let(:embed_path) { "/l/#{product.unique_permalink}/landing/embed" }

    it_behaves_like "a surface carrying both halves of the bridge"
  end
end
