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

    it "returns custom HTML and its public URL from GET" do
      @product.update!(custom_html: "<section>Published HTML</section>")

      get :show, params: { format: :json, access_token: @token.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("product", "custom_html")).to eq("<section>Published HTML</section>")
      expect(body.dig("product", "custom_html_url")).to include("/l/#{@product.unique_permalink}")
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
  end
end
