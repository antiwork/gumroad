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
      expect(response.body).to include(%(sandbox="#{RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX}"))
      expect(response.body).to include("allow-popups")
      expect(response.body).not_to include("allow-same-origin")
      expect(response.body).not_to include("allow-top-navigation")
      # The wrapper owns the base checkout URL; seller HTML sends either the
      # "gumroad:checkout" signal (string) or a structured payload with selection.
      expect(response.body).to include(%(BASE_CHECKOUT = "/l/#{product.unique_permalink}?wanted=true"))
      expect(response.body).to include('e.data === "gumroad:checkout"')
      expect(response.body).to include('e.data.type === "gumroad:checkout"')
      # Opaque-origin e.origin isn't usable (Chrome reports "null", other
      # engines report the frame URL). Gate on e.source only.
      expect(response.body).not_to include('e.origin !== "null"')
      # Script carries a nonce — script-src has no 'unsafe-inline', so without
      # it the listener would be CSP-blocked in the browser. It also opts out of
      # Rocket Loader so Cloudflare doesn't rewrite the inline handler and drop
      # the nonce before the browser sees it.
      expect(response.body).to match(/<script nonce="[^"]+" data-cfasync="false">/)
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

    describe "same-tab navigation to the seller's own pages" do
      it "installs the validating gumroad:navigate listener in the trusted wrapper" do
        get :show, params: { id: product.unique_permalink }

        # The sandbox blocks the iframe from navigating the top-level window, so
        # a plain link to the seller's storefront used to dead-end on an error
        # page unless the seller added target="_blank". The bridge lets the
        # trusted wrapper do the navigation after re-validating the hostname.
        expect(response.body).to include('e.data.type === "gumroad:navigate"')
        # The hostname check moved into the shared gumroadNavigationTarget
        # helper so the interceptor and the wrapper cannot disagree; the wrapper
        # still refuses anything the helper does not resolve.
        expect(response.body).to include("storeHostnames.indexOf(url.hostname) !== -1")
        expect(response.body).to include("gumroadNavigationTarget(url, STORE_HOSTNAMES)")
        expect(response.body).to include("if (destination === null) return;")
        expect(response.body).to include(%(STORE_HOSTNAMES = ["#{URI.parse(seller.subdomain_with_protocol).host}"]))
      end

      it "injects the click bridge into the sandboxed landing document" do
        get :landing_iframe_content, params: { id: product.unique_permalink }

        expect(response.body).to include("data-gumroad-navigation-bridge")
        expect(response.body).to include('type: "gumroad:navigate"')
      end

      it "allowlists the seller's live custom domain alongside their subdomain" do
        create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include("shop.example.com")
      end

      it "does not allowlist a custom domain the seller never verified" do
        create(:custom_domain, user: seller, domain: "unproven.example.com")

        get :show, params: { id: product.unique_permalink }

        # Anyone can type a domain they don't own into the custom-domain field.
        # Until DNS verification passes, sending a visitor's tab there would be
        # navigating them to a host the seller hasn't shown they control.
        expect(response.body).not_to include("unproven.example.com")
      end

      it "never allowlists a shared Gumroad host" do
        @request.host = VALID_REQUEST_HOSTS.first

        get :show, params: { id: product.unique_permalink }

        # request.host is only trusted when it is one of the seller's own hosts.
        # Otherwise a seller's HTML could navigate the visitor's tab to any
        # gumroad.com path, which is exactly what the sandbox prevents.
        expect(response.body).not_to include(%("#{VALID_REQUEST_HOSTS.first}"))
      end
    end

    describe "social share image meta tags" do
      it "omits og:image and twitter:image when the product has no thumbnail or cover" do
        get :show, params: { id: product.unique_permalink }

        expect(response.body).not_to include(%(property="og:image"))
        expect(response.body).not_to include(%(property="twitter:image"))
      end

      it "uses the thumbnail when one is set" do
        thumbnail = create(:thumbnail, product:)

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(thumbnail.url)}">))
        expect(response.body).to include(%(<meta property="twitter:card" content="summary_large_image">))
        expect(response.body).to include(%(<meta property="twitter:image" content="#{ERB::Util.h(thumbnail.url)}">))
      end

      it "falls back to the cover image when there is no thumbnail" do
        create(:asset_preview, link: product, unsplash_url: "https://images.unsplash.com/example.jpeg", attach: false)

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta property="og:image" content="https://images.unsplash.com/example.jpeg">))
        expect(response.body).to include(%(<meta property="twitter:image" content="https://images.unsplash.com/example.jpeg">))
      end

      it "falls back to the generated poster for an uploaded video cover" do
        product.preview = Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "thing.mov"), "video/quicktime")
        allow_any_instance_of(AssetPreview).to receive(:video_poster_url).and_return("https://files.example.com/poster.jpg")

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta property="og:image" content="https://files.example.com/poster.jpg">))
        expect(response.body).to include(%(<meta property="twitter:image" content="https://files.example.com/poster.jpg">))
      end

      it "prefers the thumbnail over the cover when both exist" do
        thumbnail = create(:thumbnail, product:)
        create(:asset_preview, link: product, unsplash_url: "https://images.unsplash.com/example.jpeg", attach: false)

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(thumbnail.url)}">))
        expect(response.body).not_to include(%(content="https://images.unsplash.com/example.jpeg"))
      end
    end

    describe "search engine visibility (crawlable wrapper)" do
      it "includes a meta description derived from the product description" do
        product.update!(description: "<p>A hands-on guide to <strong>etching</strong> sliders.</p>")

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta name="description" content="A hands-on guide to etching sliders.">))
        expect(response.body).to include(%(<meta property="og:description" content="A hands-on guide to etching sliders.">))
      end

      it "falls back to the standard page's default description when the product has none" do
        product.update!(description: nil)

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta name="description" content="Available on Gumroad">))
      end

      it "falls back to the default description when the description is markup with no text" do
        product.update!(description: "<p><br></p>")

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta name="description" content="Available on Gumroad">))
      end

      it "escapes HTML-special characters in the meta description" do
        product.update!(description: %(Quotes " and <tags> & ampersands))

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<meta name="description" content="Quotes &quot; and &amp; ampersands">))
      end

      it "renders the same Product JSON-LD as the standard product page" do
        allow_any_instance_of(Link).to receive(:structured_data).and_return(
          { "@context" => "https://schema.org", "@type" => "Product", "name" => product.name }
        )

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<script type="application/ld+json">))
        expect(response.body).to include(%("@type":"Product"))
      end

      it "omits the JSON-LD script when the product has no structured data" do
        allow_any_instance_of(Link).to receive(:structured_data).and_return({})

        get :show, params: { id: product.unique_permalink }

        expect(response.body).not_to include("application/ld+json")
      end

      it "escapes closing script tags inside the JSON-LD payload" do
        allow_any_instance_of(Link).to receive(:structured_data).and_return(
          { "@type" => "Product", "description" => %(bad</script><script>alert(1)</script>) }
        )

        get :show, params: { id: product.unique_permalink }

        expect(response.body).not_to include(%(bad</script><script>alert(1)</script>))
        expect(response.body).to include("bad\\u003c/script\\u003e")
      end

      it "includes a visually-hidden crawlable summary with the product name and description" do
        product.update!(description: "<p>Crawlable summary text.</p>")

        get :show, params: { id: product.unique_permalink }

        expect(response.body).to include(%(<div class="seo-summary">))
        expect(response.body).to include("<h1>#{ERB::Util.h(product.name)}</h1>")
        expect(response.body).to include("<p>Crawlable summary text.</p>")
      end
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
      expect(response.headers["Content-Security-Policy"]).to include("sandbox #{RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX}")
      expect(response.headers["Content-Security-Policy"]).to include("frame-src https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com")
      # The shared Tailwind build loads from the asset host as an external
      # stylesheet, so style-src must allow it.
      expect(response.headers["Content-Security-Policy"]).to include("style-src 'unsafe-inline' #{RendersCustomHtmlPages::PAGES_TAILWIND_ASSET_HOST}")
      expect(response.headers["Content-Security-Policy"]).not_to include("allow-same-origin")
      expect(response.headers["Content-Security-Policy"]).not_to include("allow-top-navigation")
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

    it "serves a Rocket Loader-safe delegated checkout bridge" do
      product.update!(custom_html: %(<button data-gumroad-action="buy">Buy</button>))

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response.body).to include(%(<script data-cfasync="false">))
      expect(response.body).to include(%(target.closest('[data-gumroad-action="buy"]')))
      expect(response.body).to include("e.preventDefault();")
      expect(response.body).not_to include("stopImmediatePropagation")
      expect(response.body).to include(%(parent.postMessage({type:"gumroad:checkout",params:params},"*");))
      expect(response.body).not_to include("onclick=")
    end
  end

  describe ".pages_tailwind_head" do
    let(:manifest_path) { Rails.root.join("public/pages-tailwind-manifest.json") }
    let(:css_path) { Rails.root.join("public/pages-tailwind.css") }
    let(:fingerprinted_path) { Rails.root.join("public", "assets/pages/pages-tailwind-0123456789ab.css") }

    before do
      described_class.remove_instance_variable(:@pages_tailwind_head) if described_class.instance_variable_defined?(:@pages_tailwind_head)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
    end

    after do
      described_class.remove_instance_variable(:@pages_tailwind_head) if described_class.instance_variable_defined?(:@pages_tailwind_head)
    end

    it "links to the fingerprinted stylesheet on the asset host when the manifest and file exist" do
      allow(File).to receive(:exist?).with(manifest_path).and_return(true)
      allow(File).to receive(:read).with(manifest_path).and_return({ "pages-tailwind.css" => "assets/pages/pages-tailwind-0123456789ab.css" }.to_json)
      allow(File).to receive(:exist?).with(fingerprinted_path).and_return(true)

      expect(described_class.pages_tailwind_head).to eq(
        %(<link rel="stylesheet" href="#{RendersCustomHtmlPages::PAGES_TAILWIND_ASSET_HOST}/assets/pages/pages-tailwind-0123456789ab.css">)
      )
    end

    it "falls back to inlining the un-fingerprinted build when the manifest is missing" do
      allow(File).to receive(:exist?).with(manifest_path).and_return(false)
      allow(File).to receive(:exist?).with(css_path).and_return(true)
      allow(File).to receive(:read).with(css_path).and_return(".hero{display:block}")

      expect(described_class.pages_tailwind_head).to eq("<style>.hero{display:block}</style>")
    end

    it "falls back to inlining when the manifest points at a file that is not on disk" do
      allow(File).to receive(:exist?).with(manifest_path).and_return(true)
      allow(File).to receive(:read).with(manifest_path).and_return({ "pages-tailwind.css" => "assets/pages/pages-tailwind-0123456789ab.css" }.to_json)
      allow(File).to receive(:exist?).with(fingerprinted_path).and_return(false)
      allow(File).to receive(:exist?).with(css_path).and_return(true)
      allow(File).to receive(:read).with(css_path).and_return(".hero{display:block}")

      expect(described_class.pages_tailwind_head).to eq("<style>.hero{display:block}</style>")
    end

    it "ignores a manifest entry that does not look like a build output" do
      allow(File).to receive(:exist?).with(manifest_path).and_return(true)
      allow(File).to receive(:read).with(manifest_path).and_return({ "pages-tailwind.css" => "../../etc/passwd" }.to_json)
      allow(File).to receive(:exist?).with(css_path).and_return(true)
      allow(File).to receive(:read).with(css_path).and_return(".hero{display:block}")

      expect(described_class.pages_tailwind_head).to eq("<style>.hero{display:block}</style>")
    end

    it "does not memoize a missing Tailwind build artifact" do
      allow(File).to receive(:exist?).with(manifest_path).and_return(false)
      allow(File).to receive(:exist?).with(css_path).and_return(false, true)
      allow(File).to receive(:read).with(css_path).and_return(".hero{display:block}")

      expect(described_class.pages_tailwind_head).to eq("")
      expect(described_class.pages_tailwind_head).to eq("<style>.hero{display:block}</style>")
    end
  end

  describe ".tailwind_v3_gradient_compat_head" do
    # Regression coverage for gumroad-private#1357: our injected Tailwind v4
    # build registers the gradient custom properties as strictly <color> via
    # @property, which is document-global. Tailwind v3 (loaded from the CDN by
    # seller/agent pages) writes "<color> <position>" into those same
    # properties, so the browser rejects the declaration and substitutes the
    # registered initial-value #0000 — every v3 gradient silently renders
    # transparent. Re-registering with syntax:"*" accepts v3's value shape.
    it "emits the universal-syntax re-registration for a page that loads the v3 CDN" do
      html = described_class.tailwind_v3_gradient_compat_head(
        %(<script src="https://cdn.tailwindcss.com"></script><div class="bg-gradient-to-br from-red-500 to-blue-500"></div>)
      )

      expect(html).to include("@property --tw-gradient-from")
      expect(html).to include(%(syntax:"*"))
      # All six variables v3 writes into must be re-registered: the three color
      # stops and the three positions (v3 writes an empty value into the
      # position variables, which fails v4's <length-percentage> registration
      # the same way a "color position" pair fails its <color> registration).
      %w[
        --tw-gradient-from --tw-gradient-via --tw-gradient-to
        --tw-gradient-from-position --tw-gradient-via-position --tw-gradient-to-position
      ].each do |property|
        expect(html).to include("@property #{property}{")
      end
      expect(html).not_to include(%(syntax:"<color>"))
    end

    it "emits the shim when the CDN host is written in a different case" do
      # Hostnames are case-insensitive and the sanitizer downcases before
      # comparing, so this page really does load Tailwind v3 and needs the shim.
      expect(described_class.tailwind_v3_gradient_compat_head(
               %(<script src="https://CDN.Tailwindcss.com"></script><div class="bg-gradient-to-br from-red-500 to-blue-500"></div>)
             )).to include(%(@property --tw-gradient-from{syntax:"*"))
    end

    it "emits nothing for a page that does not load the v3 CDN" do
      expect(described_class.tailwind_v3_gradient_compat_head(
               %(<div class="bg-linear-to-br from-red-500 to-blue-500">no v3 here</div>)
             )).to eq("")
    end

    it "emits nothing for blank or nil page HTML" do
      expect(described_class.tailwind_v3_gradient_compat_head(nil)).to eq("")
      expect(described_class.tailwind_v3_gradient_compat_head("")).to eq("")
    end
  end

  describe "GET landing_iframe_content Tailwind v3 gradient compatibility" do
    it "injects the compatibility shim AFTER the platform stylesheet when the page loads the v3 CDN" do
      # The test environment has no built Tailwind artifact, so pages_tailwind_head
      # returns "" here and the real <link> never appears. Stub it, because the
      # ORDER of the two is the whole point of this test: for duplicate @property
      # rules the LAST registration wins, so a shim emitted before our v4
      # stylesheet would be overwritten by it and fix nothing.
      allow(described_class).to receive(:pages_tailwind_head)
        .and_return(%(<link rel="stylesheet" href="https://assets.example.com/pages-tailwind-abc.css">))
      product.update!(custom_html: %(<script src="https://cdn.tailwindcss.com"></script><div class="bg-gradient-to-br from-red-500 to-blue-500">panel</div>))

      get :landing_iframe_content, params: { id: product.unique_permalink }

      shim_position = response.body.index("@property --tw-gradient-from")
      tailwind_position = response.body.index("pages-tailwind-abc.css")
      expect(shim_position).to be_present
      expect(tailwind_position).to be_present
      expect(shim_position).to be > tailwind_position
    end

    it "does not inject the shim for a page with no v3 CDN script" do
      product.update!(custom_html: %(<div class="bg-linear-to-br from-red-500 to-blue-500">panel</div>))

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response.body).not_to include("@property --tw-gradient-from")
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

  describe "owner live-reload poll on the wrapper" do
    it "injects the version poll for the signed-in owner" do
      sign_in seller

      get :show, params: { id: product.unique_permalink }

      expect(response.body).to include("/l/#{product.unique_permalink}/landing/version")
    end

    it "omits the poll for anonymous visitors" do
      get :show, params: { id: product.unique_permalink }

      expect(response.body).not_to include("/landing/version")
    end
  end

  describe "GET landing_version" do
    it "reports the live page with a version token to the owner" do
      sign_in seller

      get :landing_version, params: { id: product.unique_permalink }

      expect(response).to be_successful
      expect(response.parsed_body["present"]).to be(true)
      expect(response.parsed_body["version"]).to be_a(Integer)
    end

    it "reports present:false once the custom_html is cleared" do
      sign_in seller
      product.update!(custom_html: "")

      get :landing_version, params: { id: product.unique_permalink }

      expect(response.parsed_body["present"]).to be(false)
    end

    it "reports present:false to an anonymous caller, never leaking the edit timestamp" do
      get :landing_version, params: { id: product.unique_permalink }

      expect(response.parsed_body["present"]).to be(false)
      expect(response.parsed_body["version"]).to be_nil
    end
  end
end
