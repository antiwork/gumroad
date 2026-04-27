# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::LicensesController do
  describe "POST lookup" do
    include_examples "admin api authorization required", :post, :lookup

    let(:product) { create(:product, name: "Licensed product") }
    let(:purchase) { create(:free_purchase, link: product, email: "buyer@example.com") }
    let(:license) { create(:license, link: product, purchase:, uses: 3) }

    it "returns license and purchase details for a license key" do
      post :lookup, params: { license_key: license.serial }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["uses"]).to eq(3)

      license_payload = response.parsed_body["license"]
      expect(license_payload).to include(
        "email" => "buyer@example.com",
        "product_id" => product.external_id_numeric.to_s,
        "product_name" => "Licensed product",
        "purchase_id" => purchase.external_id_numeric.to_s,
        "uses" => 3,
        "enabled" => true,
        "disabled" => false
      )

      expect(response.parsed_body.dig("purchase", "id")).to eq(purchase.external_id_numeric.to_s)
      expect(response.parsed_body.dig("purchase", "email")).to eq("buyer@example.com")
    end

    it "returns a bad request when the license key is missing" do
      post :lookup

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "license_key is required" }.as_json)
    end

    it "returns not found when the license key does not exist" do
      post :lookup, params: { license_key: "missing-key" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "License not found" }.as_json)
    end
  end
end
