# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AgentCustomHtmlPreviewsController do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  before { Feature.activate_user(:custom_html_pages, seller) }

  # POST create stages the computed document in Redis and returns a URL; fetch it through GET show
  # the way the preview iframe does, so these specs exercise the exact path the card uses.
  def staged_preview_document
    preview_url = response.parsed_body["preview_url"]
    expect(preview_url).to be_present
    get :show, params: { token: preview_url.split("/").last }
    expect(response).to have_http_status(:ok)
    response.body
  end

  describe "POST create" do
    let(:valid_params) { { endpoint: "update_user_custom_html", custom_html: "<section><h1>New page</h1></section>" } }

    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { valid_params }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_params) { valid_params }
      let(:request_format) { :json }
    end

    it "renders an error when the custom_html_pages feature is off" do
      Feature.deactivate_user(:custom_html_pages, seller)

      post :create, params: valid_params, format: :json

      expect(response.parsed_body).to eq("success" => false, "error" => "Custom HTML pages are not enabled on this account.")
    end

    context "for update_user_custom_html" do
      it "stages the proposed page wrapped in the sandboxed landing document and returns its URL" do
        post :create, params: valid_params, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["preview_url"]).to match(%r{/agent/custom_html_previews/[A-Za-z0-9_-]+\z})

        html = staged_preview_document
        expect(html).to include("<h1>New page</h1>")
        expect(html).to include("<!doctype html>")
        # The same sandbox-compat shim the live /landing/embed document carries.
        expect(html).to include("data-gumroad-sandbox-shim")
      end

      it "does not embed a meta CSP — the real policy arrives as GET show's response header" do
        post :create, params: valid_params, format: :json

        expect(staged_preview_document).not_to include(%(http-equiv="Content-Security-Policy"))
      end

      it "does not carry the scroll-to-change script — a whole-page update has no single changed area" do
        post :create, params: valid_params, format: :json

        html = staged_preview_document
        expect(html).not_to include("data-gumroad-preview-scroll")
        expect(html).not_to include(RendersCustomHtmlPages::PREVIEW_CHANGED_MARKER)
      end

      it "sanitizes the proposed HTML the same way applying it would" do
        post :create, params: { endpoint: "update_user_custom_html", custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Hi</h1></section>) }, format: :json

        expect(response.parsed_body["success"]).to be(true)
        html = staged_preview_document
        expect(html).to include("<h1>Hi</h1>")
        expect(html).not_to include("evil.com")
      end

      it "previews the default storefront for a proposal that clears the page" do
        post :create, params: { endpoint: "update_user_custom_html", custom_html: "" }, format: :json

        expect(response.parsed_body["success"]).to be(true)
        # Clearing unpublishes the custom page, so the profile falls back to the default
        # storefront — the preview shows that render rather than erroring out.
        expect(staged_preview_document).to eq(Pages::DefaultProfileDocument.render(seller))
      end

      it "previews the default storefront when the proposed page sanitizes down to nothing" do
        # Applying stores `result.html.presence`, so a page that is all disallowed markup
        # unpublishes — the preview mirrors that outcome.
        post :create, params: { endpoint: "update_user_custom_html", custom_html: %(<script src="https://evil.com/x.js"></script>) }, format: :json

        expect(response.parsed_body["success"]).to be(true)
        expect(staged_preview_document).to eq(Pages::DefaultProfileDocument.render(seller))
      end

      it "renders an error when the custom_html key is missing, mirroring the apply endpoint" do
        # Api::V2::UsersController#update_custom_html rejects a request without the key, so a
        # proposal missing it must not preview successfully and enable Confirm.
        post :create, params: { endpoint: "update_user_custom_html" }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "The proposed update is missing its custom_html value.")
      end

      it "renders an error when custom_html is not a string, mirroring the apply endpoint" do
        post :create, params: { endpoint: "update_user_custom_html", custom_html: { nested: "value" } }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "custom_html must be a string.")
      end
    end

    context "for edit_user_custom_html" do
      before do
        seller.custom_html = "<section><h1>Old headline</h1><p>Keep me</p></section>"
        seller.save!
      end

      it "stages the current page with the proposed edit spliced in" do
        post :create, params: { endpoint: "edit_user_custom_html", find: "<h1>Old headline</h1>", replace: "<h1>New headline</h1>" }, format: :json

        expect(response.parsed_body["success"]).to be(true)
        html = staged_preview_document
        expect(html).to include("<h1>New headline</h1>")
        expect(html).to include("<p>Keep me</p>")
        expect(html).not_to include("Old headline")
      end

      it "marks the changed area and ships the scroll-to-change script so the preview opens on the edit" do
        post :create, params: { endpoint: "edit_user_custom_html", find: "<h1>Old headline</h1>", replace: "<h1>New headline</h1>" }, format: :json

        html = staged_preview_document
        expect(html).to include("#{RendersCustomHtmlPages::PREVIEW_CHANGED_MARKER}<h1>New headline</h1>")
        expect(html).to include("data-gumroad-preview-scroll")
      end

      it "falls back to the unmarked page when the marker cannot land as a comment node" do
        # The edit matches inside an attribute value, so splicing a comment there would corrupt
        # the markup — the marked variant no longer sanitizes to the real result and is discarded.
        seller.custom_html = %(<section><p class="headline-old">Hi</p></section>)
        seller.save!

        post :create, params: { endpoint: "edit_user_custom_html", find: "headline-old", replace: "headline-new" }, format: :json

        expect(response.parsed_body["success"]).to be(true)
        html = staged_preview_document
        expect(html).to include(%(class="headline-new"))
        expect(html).not_to include(RendersCustomHtmlPages::PREVIEW_CHANGED_MARKER)
        expect(html).not_to include("data-gumroad-preview-scroll")
      end

      it "renders an error when the snippet no longer matches the current page" do
        post :create, params: { endpoint: "edit_user_custom_html", find: "<h1>Gone</h1>", replace: "<h1>New</h1>" }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "The snippet to replace no longer appears in the current page.")
      end

      it "renders an error when the snippet matches more than once" do
        seller.custom_html = "<section><p>Twice</p><p>Twice</p></section>"
        seller.save!

        post :create, params: { endpoint: "edit_user_custom_html", find: "<p>Twice</p>", replace: "<p>Once</p>" }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "The snippet to replace matches 2 places in the current page.")
      end

      it "renders an error when there is no page to edit" do
        seller.custom_html = nil
        seller.save!

        post :create, params: { endpoint: "edit_user_custom_html", find: "<p>a</p>", replace: "<p>b</p>" }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "There is no custom HTML page to edit.")
      end

      it "renders an error when find is not a string, mirroring the apply endpoint" do
        post :create, params: { endpoint: "edit_user_custom_html", find: { nested: "value" }, replace: "<p>b</p>" }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "The proposed edit is missing the snippet to replace.")
      end

      it "renders an error when replace is missing, mirroring the apply endpoint" do
        # Api::V2::UsersController#edit_custom_html requires replace to be a string (it has no
        # default), so a proposal without one must fail the preview rather than enable Confirm.
        post :create, params: { endpoint: "edit_user_custom_html", find: "<h1>Old headline</h1>" }, format: :json

        expect(response.parsed_body).to eq("success" => false, "error" => "The proposed edit is missing the replacement text.")
      end

      it "previews the default storefront when the edit empties the page" do
        # An edit that deletes the whole content unpublishes the page on apply (the real endpoint
        # stores the sanitized result's presence), so the preview shows the default storefront.
        # `find` is read back from the record because saving may normalize the markup.
        post :create, params: { endpoint: "edit_user_custom_html", find: seller.reload.custom_html, replace: "" }, format: :json

        body = response.parsed_body
        expect(body["error"]).to be_nil
        expect(body["success"]).to be(true)
        expect(staged_preview_document).to eq(Pages::DefaultProfileDocument.render(seller))
      end

      it "inserts replacements containing backslashes literally" do
        seller.custom_html = "<section><p>Old</p></section>"
        seller.save!

        post :create, params: { endpoint: "edit_user_custom_html", find: "<p>Old</p>", replace: "<p>Path C:\\new</p>" }, format: :json

        expect(response.parsed_body["success"]).to be(true)
        expect(staged_preview_document).to include("C:\\new")
      end
    end

    it "renders an error for a write that has no page preview" do
      post :create, params: { endpoint: "update_product", custom_html: "<p>hi</p>" }, format: :json

      expect(response.parsed_body).to eq("success" => false, "error" => "This change doesn't have a page preview.")
    end
  end

  describe "GET show" do
    def stage_preview
      post :create, params: { endpoint: "update_user_custom_html", custom_html: "<section><h1>New page</h1></section>" }, format: :json
      response.parsed_body["preview_url"].split("/").last
    end

    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { token: "sometoken" } }
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_params) { { token: "sometoken" } }
    end

    it "serves the staged document with the same CSP response header as the live embed endpoint" do
      # The whole reason the preview is served by URL instead of iframe srcdoc: only a response
      # header can carry a CSP that permits the page's inline scripts (srcdoc inherits the
      # dashboard's policy, which blocks them). This header must never drift from the live page's.
      token = stage_preview

      get :show, params: { token: }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<h1>New page</h1>")
      expect(response.headers["Content-Security-Policy"]).to eq(RendersCustomHtmlPages::CUSTOM_HTML_CSP)
      expect(response.headers["Content-Security-Policy"]).to include("script-src 'unsafe-inline'")
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "renders the expired notice for an unknown or expired token" do
      get :show, params: { token: "unknown-token" }

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("This preview has expired.")
    end

    it "does not serve a document staged for another seller" do
      # Tokens are namespaced by seller id in Redis, so even a leaked token is useless to any
      # other account.
      other_seller = create(:user)
      other_token = SecureRandom.urlsafe_base64(24)
      $redis.set(RedisKey.agent_custom_html_preview(other_seller.id, other_token), "<!doctype html><p>secret</p>", ex: 60)

      get :show, params: { token: other_token }

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("secret")
    end

    it "stages documents with an expiry so abandoned previews clean themselves up" do
      token = stage_preview

      ttl = $redis.ttl(RedisKey.agent_custom_html_preview(seller.id, token))
      expect(ttl).to be > 0
      expect(ttl).to be <= described_class::PREVIEW_DOCUMENT_TTL.to_i
    end

    it "evicts a seller's oldest staged documents beyond the per-seller cap" do
      # Documents run up to ~500 KB each, so an uncapped seller could grow the shared Redis
      # without bound by scripting the stage endpoint.
      stub_const("#{described_class}::MAX_STAGED_PREVIEWS_PER_SELLER", 2)

      oldest_token = stage_preview
      kept_tokens = [stage_preview, stage_preview]

      expect($redis.exists?(RedisKey.agent_custom_html_preview(seller.id, oldest_token))).to eq(false)
      kept_tokens.each do |token|
        expect($redis.exists?(RedisKey.agent_custom_html_preview(seller.id, token))).to eq(true)
      end

      get :show, params: { token: oldest_token }
      expect(response).to have_http_status(:not_found)

      get :show, params: { token: kept_tokens.last }
      expect(response).to have_http_status(:ok)
    end
  end
end
