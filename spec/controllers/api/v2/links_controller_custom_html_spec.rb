# frozen_string_literal: true

require "spec_helper"

describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @other_user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
    @other_product = create(:product, user: @other_user)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
    Feature.activate_user(:custom_html_pages, @user)
  end

  describe "PUT 'update' with custom_html" do
    it "sanitizes custom HTML before storing while allowing inline JavaScript" do
      html = <<~HTML
        <section onclick="openModal()">
          <script>window.ready = true;</script>
          <script src="https://evil.com/x.js"></script>
          <a href="javascript:alert(1)">Click</a>
        </section>
      HTML

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: html }

      expect(response).to have_http_status(:ok)
      stored_html = @product.reload.custom_html
      expect(stored_html).to include(%(onclick="openModal()"))
      expect(stored_html).to include("<script>window.ready = true;</script>")
      expect(stored_html).not_to include("evil.com")
      expect(stored_html).not_to include("javascript:")
    end

    it "returns custom HTML from GET" do
      @product.update!(custom_html: "<section>Published HTML</section>")

      get :show, params: { format: :json, access_token: @token.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("product", "custom_html")).to eq("<section>Published HTML</section>")
    end

    it "omits custom_html from the slim list endpoint to avoid bloating responses" do
      @product.update!(custom_html: "<section>Published HTML</section>")

      get :index, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      product_json = JSON.parse(response.body)["products"].find { |p| p["id"] == @product.external_id }
      expect(product_json).not_to have_key("custom_html")
    end

    it "does not load custom HTML pages for the slim list endpoint" do
      @product.update!(custom_html: "<section>Published HTML</section>")
      page_queries = []

      counter = lambda do |*, payload|
        sql = payload[:sql]
        page_queries << sql if sql.match?(/\bFROM\s+[`"]?pages[`"]?\b/i)
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :index, params: { format: :json, access_token: @token.token }
      end

      expect(response).to have_http_status(:ok)
      expect(page_queries).to be_empty
    end

    it "clears custom HTML when passed nil" do
      @product.update!(custom_html: "<section>Published HTML</section>")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: nil }

      expect(response).to have_http_status(:ok)
      expect(@product.reload.custom_html).to be_nil
    end

    it "returns 401 without a token" do
      put :update, params: { format: :json, id: @product.external_id, custom_html: "<section>HTML</section>" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not reveal another seller's product while updating custom_html" do
      put :update, params: { format: :json, access_token: @token.token, id: @other_product.external_id, custom_html: "<section>HTML</section>" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "success" => false, "message" => "The product was not found." })
      expect(@other_product.reload.custom_html).to be_nil
    end

    it "returns 404 when the id only matches another seller's custom permalink" do
      @other_product.update!(custom_permalink: "another-sellers-page")

      put :update, params: { format: :json, access_token: @token.token, id: "another-sellers-page", custom_html: "<section>HTML</section>" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "success" => false, "message" => "The product was not found." })
    end

    it "rejects HTML over the size limit before the sanitizer parses it" do
      # The cheap length guard must fire before Nokogiri touches the payload, so
      # an oversized body can't force expensive parsing on the rate-limited path.
      expect(Ai::PageSanitizer).not_to receive(:sanitize_with_report)
      oversized = "<section>#{"a" * Page::MAX_CUSTOM_HTML_LENGTH}</section>"

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: oversized }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["message"]).to match(/too long/i)
      expect(@product.reload.custom_html).to be_nil
    end

    it "rejects a non-string custom_html with a controlled error, not a 500" do
      @product.update!(custom_html: "<section>Existing</section>")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: %w[not a string] }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["message"]).to match(/must be a string/i)
      # The existing page is untouched — the bad request didn't clear or crash it.
      expect(@product.reload.custom_html).to eq("<section>Existing</section>")
    end

    it "includes landing_url in the response so the agent can echo where the page is now live" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section>HTML</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body.dig("product", "landing_url")).to eq(@product.long_url)
    end

    it "returns previous_custom_html so the agent has one-shot recovery from an overwrite" do
      @product.update!(custom_html: "<section>Old HTML</section>")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section>New HTML</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["previous_custom_html"]).to eq("<section>Old HTML</section>")
    end

    it "returns previous_custom_html as null on the first push (nothing to recover)" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section>First HTML</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body).to have_key("previous_custom_html")
      expect(body["previous_custom_html"]).to be_nil
    end

    it "returns previous_custom_html when clearing custom_html (the recover-after-reset case)" do
      @product.update!(custom_html: "<section>About to be cleared</section>")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: nil }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["previous_custom_html"]).to eq("<section>About to be cleared</section>")
    end

    it "omits previous_custom_html when the request doesn't touch custom_html" do
      @product.update!(custom_html: "<section>Existing</section>")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, name: "Renamed product" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body).not_to have_key("previous_custom_html")
    end

    it "returns a sanitization_report listing what was stripped" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: %(<section><script src="https://evil.com/x.js"></script><a href="javascript:alert(1)">x</a></section>) }

      body = JSON.parse(response.body)
      report = body["sanitization_report"]
      expect(report["total_removed"]).to eq(2)
      expect(report["removed_tags"]).to include(a_hash_including("tag" => "script", "reason" => "script src host not allowed"))
      expect(report["removed_attributes"]).to include(a_hash_including("attribute" => "href", "reason" => "javascript: URL blocked"))
    end

    it "returns a warning when custom HTML has no buy affordance" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section><h1>Landing page</h1></section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["warning"]).to include("does not include a buy element")
    end

    it "does not return the buy warning when custom HTML has a buy element" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: %(<section><a data-gumroad-action="buy">Buy now</a></section>) }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body).not_to have_key("warning")
    end

    it "joins offer-code and buy-affordance warnings in the existing warning string" do
      @product.update!(price_cents: 2_00)
      create(:offer_code, user: @user, products: [@product], code: "SAVE100", amount_cents: 1_00, currency_type: @product.price_currency_type)

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, price: 1_50, custom_html: "<section><h1>Landing page</h1></section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["warning"]).to be_a(String)
      expect(body["warning"]).to include("SAVE100")
      expect(body["warning"]).to include("does not include a buy element")
    end

    it "applies custom_html alongside other attribute changes without choking on the row lock" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, name: "Renamed", custom_html: "<section>Combined update</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      @product.reload
      expect(@product.name).to eq("Renamed")
      expect(@product.custom_html).to include("Combined update")
    end
  end

  describe "POST 'preview_custom_html'" do
    it "returns the sanitized HTML without writing to the product" do
      input = <<~HTML
        <section>
          <script src="https://evil.com/x.js"></script>
          <a href="javascript:alert(1)">Click</a>
          <h1>Hello</h1>
        </section>
      HTML

      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: input }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["custom_html"]).to include("<h1>Hello</h1>")
      expect(body["custom_html"]).not_to include("evil.com")
      expect(body["custom_html"]).not_to include("javascript:")
      expect(@product.reload.custom_html).to be_nil
    end

    it "rejects oversized input before the sanitizer parses it" do
      expect(Ai::PageSanitizer).not_to receive(:sanitize_with_report)
      oversized = "<section>#{"a" * Page::MAX_CUSTOM_HTML_LENGTH}</section>"

      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: oversized }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["message"]).to match(/too long/i)
      expect(@product.reload.custom_html).to be_nil
    end

    it "returns success with nil custom_html when input is blank" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["custom_html"]).to be_nil
    end

    it "requires the custom_html parameter" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "success" => false, "message" => "custom_html is required." })
    end

    it "rejects non-string custom_html input" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: ["<section>HTML</section>"] }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "success" => false, "message" => "custom_html must be a string." })
    end

    it "returns nil when input sanitizes to an empty string" do
      input = %(<link rel="stylesheet" href="https://example.com/style.css">)

      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: input }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["custom_html"]).to be_nil
    end

    it "agrees with PUT update on input that sanitizes to empty" do
      input = %(<link rel="stylesheet" href="https://example.com/style.css">)

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: input }

      expect(@product.reload.custom_html).to be_nil
    end

    it "returns 401 without a token" do
      post :preview_custom_html, params: { format: :json, id: @product.external_id, custom_html: "<section>HTML</section>" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not reveal another seller's product while previewing custom_html" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @other_product.external_id, custom_html: "<section>HTML</section>" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "success" => false, "message" => "The product was not found." })
    end

    it "returns a sanitization_report alongside the sanitized HTML" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Keep</h1></section>) }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["custom_html"]).to include("<h1>Keep</h1>")
      expect(body["sanitization_report"]["total_removed"]).to eq(1)
      expect(body["sanitization_report"]["removed_tags"].first["reason"]).to eq("script src host not allowed")
    end

    it "returns a warning when the previewed custom HTML has no buy affordance" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section><h1>Landing page</h1></section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["warning"]).to include("does not include a buy element")
      expect(@product.reload.custom_html).to be_nil
    end
  end

  describe "when the custom_html_pages feature is disabled" do
    before { Feature.deactivate_user(:custom_html_pages, @user) }

    it "rejects a custom_html update with an access error and leaves the page unchanged" do
      @product.update!(custom_html: "<section>Existing</section>")

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section>New</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["message"]).to eq("You do not have access to custom HTML pages.")
      expect(@product.reload.custom_html).to eq("<section>Existing</section>")
    end

    it "allows updating other attributes when custom_html is not part of the request" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, name: "Renamed product" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(@product.reload.name).to eq("Renamed product")
    end

    it "rejects preview_custom_html with an access error" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section>HTML</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["message"]).to eq("You do not have access to custom HTML pages.")
    end
  end
end
