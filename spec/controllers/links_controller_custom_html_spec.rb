# frozen_string_literal: true

require "spec_helper"

describe LinksController, :vcr, type: :controller do
  CUSTOM_HTML_CSP = LinksController::CUSTOM_HTML_CSP

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, custom_html: "<section><h1>Live landing page</h1></section>") }

  before do
    @request.host = URI.parse(seller.subdomain_with_protocol).host
    Feature.activate_user(:custom_html_pages, seller)
  end

  describe "GET show with custom_html" do
    it "renders a wrapper page with an iframe pointing at the landing endpoint" do
      get :show, params: { id: product.unique_permalink }
      expect(response).to be_successful
      expect(response.body).to include("<title>#{product.name}</title>")
      expect(response.body).to include(%(property="og:title"))
      expect(response.body).to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
      expect(response.body).not_to include("<h1>Live landing page</h1>")
    end

    it "does not prepare the default product page before rendering the wrapper" do
      expect(controller).not_to receive(:prepare_product_page)

      get :show, params: { id: product.unique_permalink }

      expect(response).to be_successful
      expect(response.body).to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    end

    it "sandboxes the iframe without top-navigation and mediates checkout via postMessage" do
      get :show, params: { id: product.unique_permalink }
      expect(response.body).to include(%(sandbox="allow-scripts allow-forms"))
      expect(response.body).not_to include("allow-top-navigation")
      # The wrapper owns the base checkout URL; seller HTML sends either the
      # "gumroad:checkout" signal (string) or a structured payload with selection.
      expect(response.body).to include(%(BASE_CHECKOUT = "/l/#{product.unique_permalink}?wanted=true"))
      expect(response.body).to include('e.data === "gumroad:checkout"')
      expect(response.body).to include('e.data.type === "gumroad:checkout"')
      expect(response.body).to include('e.origin !== "null"')
      # Script carries a nonce — script-src has no 'unsafe-inline', so without
      # it the listener would be CSP-blocked in the browser.
      expect(response.body).to match(/<script nonce="[^"]+">/)
      # Only our own iframe can trigger checkout — gate on e.source so an
      # embedding page can't drive the navigation.
      expect(response.body).to include("e.source !== frame.contentWindow")
    end

    it "preserves URL offer codes when mediating checkout" do
      get :show, params: { id: product.unique_permalink, code: "DISCOUNT20" }

      expect(response.body).to include(%(BASE_CHECKOUT = "/l/#{product.unique_permalink}?wanted=true\\u0026code=DISCOUNT20"))
    end

    it "only honors selection-state keys the checkout actually accepts in the structured postMessage form" do
      get :show, params: { id: product.unique_permalink }

      # The wrapper builds the final checkout URL by appending whitelisted keys
      # from the iframe payload to BASE_CHECKOUT. Any key not in this list is
      # ignored, even if the buy button claims it — defense in depth against a
      # compromised seller HTML page trying to redirect to arbitrary URLs.
      expect(response.body).to include(%(ALLOWED_CHECKOUT_KEYS = ["variant","option","quantity","price","recurrence"]))
    end

    it "escapes the checkout URL for JavaScript string context" do
      allow(product).to receive(:unique_permalink).and_return(%(abc</script><script>alert(1)</script>))

      html = controller.send(:custom_html_wrapper_document, product, nonce: "nonce")

      expect(html).to include("\\u003c/script\\u003e")
      expect(html).not_to include(%(abc</script><script>alert(1)</script>))
    end

    it "falls back to the default product page when custom_html is blank" do
      product.update!(custom_html: nil)
      get :show, params: { id: product.unique_permalink }
      expect(response.body).not_to include("<h1>Live landing page</h1>")
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    end

    it "falls back to the default product page when the product is unpublished" do
      product.update!(purchase_disabled_at: Time.current)

      get :show, params: { id: product.unique_permalink }

      expect(response.body).not_to include("<h1>Live landing page</h1>")
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    end

    it "skips the wrapper when ?wanted=true and lets the checkout redirect fire" do
      get :show, params: { id: product.unique_permalink, wanted: "true" }
      expect(response).to be_redirect
      expect(response.location).to include("/checkout")
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    end
  end

  describe "GET landing_iframe_content" do
    it "renders the seller's HTML inside a chromeless document" do
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response).to be_successful
      expect(response.body).to include("<h1>Live landing page</h1>")
      expect(response.body).to start_with("<!doctype html>")
    end

    it "sticks to primary before fetching the product for the landing page HTML" do
      steps = []
      allow(ActiveRecord::Base.connection).to receive(:stick_to_primary!).and_wrap_original do |method, *args|
        steps << :stick_to_primary
        method.call(*args)
      end
      allow(controller).to receive(:fetch_product_for_show).and_wrap_original do |method, *args|
        steps << :fetch_product
        method.call(*args)
      end

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response).to be_successful
      expect(steps.index(:stick_to_primary)).to be < steps.index(:fetch_product)
    end

    it "applies the strict CSP and iframe-friendly response headers" do
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response.headers["Content-Security-Policy"]).to eq(CUSTOM_HTML_CSP)
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
      expect(response.headers["Content-Type"]).to include("text/html")
      expect(response.headers["Content-Type"]).to include("charset=utf-8")
    end

    it "404s when the product has no custom_html" do
      product.update!(custom_html: nil)
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:not_found)
    end

    it "404s when the product is unpublished" do
      product.update!(purchase_disabled_at: Time.current)

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response).to have_http_status(:not_found)
    end

    it "allows the seller to preview unpublished custom_html" do
      product.update!(purchase_disabled_at: Time.current)
      sign_in seller

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response).to be_successful
      expect(response.body).to include("<h1>Live landing page</h1>")
    end

    it "404s when requested through another seller's custom domain" do
      custom_domain = create(:custom_domain, user: create(:user), domain: "seller-a.example.com")
      @request.host = custom_domain.domain
      allow(controller).to receive(:fetch_product_for_show) { controller.instance_variable_set(:@product, product) }

      expect do
        get :landing_iframe_content, params: { id: product.unique_permalink }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end

    it "interpolates data-gumroad-field markers with live product values" do
      product.update!(custom_html: %(<h1 data-gumroad-field="name">placeholder</h1><a data-gumroad-action="buy" href="#">Buy</a>))

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response.body).to include(">#{product.name}<")
      expect(response.body).not_to include(">placeholder<")
      expect(response.body).to include(%(href="/l/#{product.unique_permalink}?wanted=true"))
    end
  end

  describe ".pages_tailwind_inline" do
    before do
      described_class.remove_instance_variable(:@pages_tailwind_inline) if described_class.instance_variable_defined?(:@pages_tailwind_inline)
    end

    after do
      described_class.remove_instance_variable(:@pages_tailwind_inline) if described_class.instance_variable_defined?(:@pages_tailwind_inline)
    end

    it "does not memoize a missing Tailwind build artifact" do
      path = Rails.root.join("public/pages-tailwind.css")
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:exist?).with(path).and_return(false, true)
      allow(File).to receive(:read).with(path).and_return(".hero{display:block}")

      expect(described_class.pages_tailwind_inline).to eq("")
      expect(described_class.pages_tailwind_inline).to eq("<style>.hero{display:block}</style>")
    end
  end

  describe "POST update (internal dashboard, session-authed Reset flow)" do
    before { sign_in seller }

    it "clears the landing page via the Reset button (custom_html: null)" do
      expect(product.reload.custom_html).to be_present

      post :update, params: { id: product.unique_permalink, custom_html: nil }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.reload.custom_html).to be_nil
    end

    it "does not clear other product fields during a custom_html-only reset" do
      product.update!(description: "Existing description")
      product.save_custom_attributes([{ name: "Material", value: "Cotton" }])
      product.save_tags!(["launch"])

      post :update, params: { id: product.unique_permalink, custom_html: nil }

      product.reload
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.description).to eq("Existing description")
      expect(product.custom_attributes).to eq([{ "name" => "Material", "value" => "Cotton" }])
      expect(product.tags.pluck(:name)).to eq(["launch"])
    end

    it "rejects publishing custom_html through the internal update path" do
      post :update, params: { id: product.unique_permalink, custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Hi</h1></section>) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error_message"]).to match(/use the api.*dashboard only supports removing/i)
      expect(product.reload.custom_html).to eq("<section><h1>Live landing page</h1></section>")
    end

    it "locks the product row before removing custom_html" do
      expect_any_instance_of(Link).to receive(:with_lock).and_call_original

      post :update, params: { id: product.unique_permalink, custom_html: nil }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.reload.custom_html).to be_nil
    end

    it "rejects a mixed custom_html update so it can't reach the destructive partial-update path" do
      # The editor strips custom_html from its full-form save and the Remove
      # button sends custom_html on its own, so a request mixing custom_html with
      # other fields is not a real client flow. Reject it rather than let it fall
      # through to the partial-update path that would clear omitted collections
      # (rich content, covers, shipping); multi-field custom_html writes go
      # through the API v2 endpoint instead.
      product.update!(description: "Existing description")

      post :update, params: { id: product.unique_permalink, name: "Renamed", custom_html: "<section>New</section>" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error_message"]).to match(/use the api.*dashboard only supports removing/i)
      product.reload
      expect(product.name).not_to eq("Renamed")
      expect(product.custom_html).to eq("<section><h1>Live landing page</h1></section>")
      expect(product.description).to eq("Existing description")
    end
  end

  describe "when the custom_html_pages feature is disabled" do
    before { Feature.deactivate_user(:custom_html_pages, seller) }

    it "renders the default product page instead of the custom_html wrapper" do
      get :show, params: { id: product.unique_permalink }

      expect(response).to be_successful
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    end

    it "404s the landing embed endpoint" do
      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response).to have_http_status(:not_found)
    end

    it "ignores custom_html on the internal update path, leaving the live page untouched" do
      sign_in seller

      post :update, params: { id: product.unique_permalink, name: "Renamed", custom_html: "<section>New HTML</section>" }

      expect(response).to be_successful
      product.reload
      expect(product.name).to eq("Renamed")
      expect(product.custom_html).to eq("<section><h1>Live landing page</h1></section>")
    end
  end
end
