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

    it "returns 403 when updating another seller's product" do
      put :update, params: { format: :json, access_token: @token.token, id: @other_product.external_id, custom_html: "<section>HTML</section>" }
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects HTML over the size limit" do
      oversized = "<section>#{"a" * Product::Validations::MAX_CUSTOM_HTML_LENGTH}</section>"

      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: oversized }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["message"]).to match(/too long/i)
      expect(@product.reload.custom_html).to be_nil
    end

    it "includes landing_url in the response so the agent can echo where the page is now live" do
      put :update, params: { format: :json, access_token: @token.token, id: @product.external_id, custom_html: "<section>HTML</section>" }

      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body.dig("product", "landing_url")).to eq(@product.long_url)
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

    it "reports validation errors without writing" do
      oversized = "<section>#{"a" * Product::Validations::MAX_CUSTOM_HTML_LENGTH}</section>"

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

    it "returns 403 when previewing for another seller's product" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, id: @other_product.external_id, custom_html: "<section>HTML</section>" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
