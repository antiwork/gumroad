# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AgentCustomHtmlPreviewsController do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  before { Feature.activate_user(:custom_html_pages, seller) }

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
      it "returns the proposed page wrapped in the sandboxed landing document" do
        post :create, params: valid_params, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["html"]).to include("<h1>New page</h1>")
        expect(body["html"]).to include("<!doctype html>")
        # The same sandbox-compat shim the live /landing/embed document carries.
        expect(body["html"]).to include("data-gumroad-sandbox-shim")
      end

      it "carries the custom-HTML CSP in a meta tag, minus the header-only sandbox directive" do
        post :create, params: valid_params, format: :json

        html = response.parsed_body["html"]
        expect(html).to include(%(http-equiv="Content-Security-Policy"))
        expect(html).to include("img-src data: blob:")
        expect(html).not_to include("sandbox allow-scripts")
      end

      it "does not carry the scroll-to-change script — a whole-page update has no single changed area" do
        post :create, params: valid_params, format: :json

        html = response.parsed_body["html"]
        expect(html).not_to include("data-gumroad-preview-scroll")
        expect(html).not_to include(RendersCustomHtmlPages::PREVIEW_CHANGED_MARKER)
      end

      it "sanitizes the proposed HTML the same way applying it would" do
        post :create, params: { endpoint: "update_user_custom_html", custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Hi</h1></section>) }, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["html"]).to include("<h1>Hi</h1>")
        expect(body["html"]).not_to include("evil.com")
      end

      it "previews the default storefront for a proposal that clears the page" do
        post :create, params: { endpoint: "update_user_custom_html", custom_html: "" }, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        # Clearing unpublishes the custom page, so the profile falls back to the default
        # storefront — the preview shows that render rather than erroring out.
        expect(body["html"]).to eq(Pages::DefaultProfileDocument.render(seller))
      end

      it "previews the default storefront when the proposed page sanitizes down to nothing" do
        # Applying stores `result.html.presence`, so a page that is all disallowed markup
        # unpublishes — the preview mirrors that outcome.
        post :create, params: { endpoint: "update_user_custom_html", custom_html: %(<script src="https://evil.com/x.js"></script>) }, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["html"]).to eq(Pages::DefaultProfileDocument.render(seller))
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

      it "returns the current page with the proposed edit spliced in" do
        post :create, params: { endpoint: "edit_user_custom_html", find: "<h1>Old headline</h1>", replace: "<h1>New headline</h1>" }, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["html"]).to include("<h1>New headline</h1>")
        expect(body["html"]).to include("<p>Keep me</p>")
        expect(body["html"]).not_to include("Old headline")
      end

      it "marks the changed area and ships the scroll-to-change script so the preview opens on the edit" do
        post :create, params: { endpoint: "edit_user_custom_html", find: "<h1>Old headline</h1>", replace: "<h1>New headline</h1>" }, format: :json

        html = response.parsed_body["html"]
        expect(html).to include("#{RendersCustomHtmlPages::PREVIEW_CHANGED_MARKER}<h1>New headline</h1>")
        expect(html).to include("data-gumroad-preview-scroll")
      end

      it "falls back to the unmarked page when the marker cannot land as a comment node" do
        # The edit matches inside an attribute value, so splicing a comment there would corrupt
        # the markup — the marked variant no longer sanitizes to the real result and is discarded.
        seller.custom_html = %(<section><p class="headline-old">Hi</p></section>)
        seller.save!

        post :create, params: { endpoint: "edit_user_custom_html", find: "headline-old", replace: "headline-new" }, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["html"]).to include(%(class="headline-new"))
        expect(body["html"]).not_to include(RendersCustomHtmlPages::PREVIEW_CHANGED_MARKER)
        expect(body["html"]).not_to include("data-gumroad-preview-scroll")
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
        expect(body["html"]).to eq(Pages::DefaultProfileDocument.render(seller))
      end

      it "inserts replacements containing backslashes literally" do
        seller.custom_html = "<section><p>Old</p></section>"
        seller.save!

        post :create, params: { endpoint: "edit_user_custom_html", find: "<p>Old</p>", replace: "<p>Path C:\\new</p>" }, format: :json

        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["html"]).to include("C:\\new")
      end
    end

    it "renders an error for a write that has no page preview" do
      post :create, params: { endpoint: "update_product", custom_html: "<p>hi</p>" }, format: :json

      expect(response.parsed_body).to eq("success" => false, "error" => "This change doesn't have a page preview.")
    end
  end
end
