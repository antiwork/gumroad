# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::UrlRedirectsController do
  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:product_file) { create(:streamable_video, link: product, stream_only: true) }
  let(:purchase) { create(:purchase, link: product) }
  let(:url_redirect) { create(:url_redirect, purchase:) }

  before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

  describe "GET show" do
    include_examples "admin api authorization required", :get, :show, { id: "nonexistent" }

    before { request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" }

    it "returns the redirect's files with their download state" do
      product_file

      get :show, params: { id: url_redirect.token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["url_redirect"]["purchase_id"]).to eq(purchase.external_id)
      expect(body["url_redirect"]["product_id"]).to eq(product.external_id)
      expect(body["url_redirect"]["files"].sole).to include(
        "id" => product_file.external_id,
        "downloads_disabled" => true,
        "download_granted" => false,
        "downloadable" => false
      )
    end

    it "returns not found for an unknown token" do
      get :show, params: { id: "nope" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Url redirect not found" }.as_json)
    end
  end

  describe "POST grant_download" do
    include_examples "admin api authorization required", :post, :grant_download, { id: "nonexistent", product_file_id: "nonexistent" }

    before { request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" }

    it "grants the file to this buyer only" do
      expect do
        post :grant_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }
      end.to change { ProductFileDownloadGrant.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["url_redirect"]["files"].sole).to include(
        "download_granted" => true,
        "downloadable" => true
      )
      expect(url_redirect.reload.is_file_downloadable?(product_file)).to eq(true)
      expect(create(:url_redirect, purchase: create(:purchase, link: product)).is_file_downloadable?(product_file)).to eq(false)
    end

    it "is idempotent" do
      post :grant_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }

      expect do
        post :grant_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }
      end.not_to change { ProductFileDownloadGrant.count }

      expect(response).to have_http_status(:ok)
    end

    it "audits the write against the url redirect" do
      expect do
        post :grant_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "url_redirects.grant_download",
        actor_user_id: admin_user.id,
        target_type: "UrlRedirect",
        target_id: url_redirect.id,
        target_external_id: url_redirect.external_id,
        route: "/internal/admin/url_redirects/[REDACTED]/grant_download",
        params_snapshot: { "id" => "[REDACTED]", "product_file_id" => product_file.external_id },
        response_status: 200
      )
      expect(AdminApiAuditLog.last.attributes.to_json).not_to include(url_redirect.token)
    end

    it "rejects the legacy shared token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      post :grant_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["message"]).to eq("per-actor admin token is required")
    end

    it "returns not found when the redirect does not exist" do
      post :grant_download, params: { id: "nope", product_file_id: product_file.external_id }

      expect(response).to have_http_status(:not_found)
    end

    it "returns not found when the file belongs to another product" do
      other_file = create(:streamable_video, stream_only: true, link: create(:product, user: seller))

      post :grant_download, params: { id: url_redirect.token, product_file_id: other_file.external_id }

      expect(response).to have_http_status(:not_found)
      expect(ProductFileDownloadGrant.count).to eq(0)
    end

    it "refuses a file whose downloads are already enabled" do
      downloadable = create(:readable_document, link: product)

      post :grant_download, params: { id: url_redirect.token, product_file_id: downloadable.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Downloads are already enabled for this file")
    end

    it "refuses a redirect that belongs to no purchase" do
      installment_redirect = create(:url_redirect, link: product, purchase: nil)

      post :grant_download, params: { id: installment_redirect.token, product_file_id: product_file.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Downloads can only be granted on a purchase's url redirect")
    end

    it "refuses a rental" do
      url_redirect.update!(is_rental: true)

      post :grant_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Rental purchases cannot be granted downloads")
    end
  end

  describe "DELETE revoke_download" do
    include_examples "admin api authorization required", :delete, :revoke_download, { id: "nonexistent", product_file_id: "nonexistent" }

    before { request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" }

    let!(:grant) { ProductFileDownloadGrant.create!(url_redirect:, product_file:) }

    it "puts the buyer back on the reader" do
      expect do
        delete :revoke_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }
      end.to change { ProductFileDownloadGrant.count }.by(-1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["url_redirect"]["files"].sole).to include("download_granted" => false, "downloadable" => false)
      expect(url_redirect.reload.is_file_downloadable?(product_file)).to eq(false)
    end

    it "audits the write" do
      delete :revoke_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "url_redirects.revoke_download",
        actor_user_id: admin_user.id,
        target_type: "UrlRedirect",
        target_id: url_redirect.id,
        target_external_id: url_redirect.external_id,
        route: "/internal/admin/url_redirects/[REDACTED]/revoke_download",
        params_snapshot: { "id" => "[REDACTED]", "product_file_id" => product_file.external_id }
      )
      expect(AdminApiAuditLog.last.attributes.to_json).not_to include(url_redirect.token)
    end

    it "is a no-op when no grant exists" do
      grant.destroy!

      expect do
        delete :revoke_download, params: { id: url_redirect.token, product_file_id: product_file.external_id }
      end.not_to change { ProductFileDownloadGrant.count }

      expect(response).to have_http_status(:ok)
    end

    it "returns not found when the file belongs to another product" do
      other_file = create(:streamable_video, stream_only: true, link: create(:product, user: seller))

      delete :revoke_download, params: { id: url_redirect.token, product_file_id: other_file.external_id }

      expect(response).to have_http_status(:not_found)
      expect(ProductFileDownloadGrant.count).to eq(1)
    end
  end
end
