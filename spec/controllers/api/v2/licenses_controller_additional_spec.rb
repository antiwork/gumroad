# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V2::LicensesController, type: :controller do
  describe "Additional edge cases for gifted bundle purchases" do
    before { stub_const("ObfuscateIds::CIPHER_KEY", "spec-test-key") }

    let(:seller) { create(:user) }
    let(:buyer) { create(:user) }
    let(:bundle_product) { create(:bundle, user: seller, price_cents: 1000) }
    let(:child_product) { create(:product, user: seller) }
    let(:gifter_email) { "gifter@example.com" }
    let(:giftee_email) { "giftee@example.com" }

    before do
      bundle_product.links << child_product
    end

    context "when verifying license for gifted bundle with child products" do
      let!(:giftee_purchase) do
        sender_purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: gifter_email, perceived_price_cents: 1000 },
            gift: { giftee_email: giftee_email }
          },
          buyer: buyer
        ).perform

        sender_purchase.reload
        gp = sender_purchase.gift_given&.giftee_purchase
        expect(gp).to be_present
        gp
      end

      let!(:license) { create(:license, link: bundle_product, purchase: giftee_purchase, serial: "BUNDLE-KEY-123") }
      let!(:child_license) { create(:license, link: child_product, purchase: giftee_purchase, serial: "CHILD-KEY-456") }

      it "verifies bundle license with bundle product_id" do
        post :verify, params: { license_key: license.serial, product_id: bundle_product.external_id }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("success" => true)
      end

      it "verifies child product license with child product_id" do
        post :verify, params: { license_key: child_license.serial, product_id: child_product.external_id }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("success" => true)
      end

      it "rejects bundle license with wrong product_id" do
        post :verify, params: { license_key: license.serial, product_id: child_product.external_id }
        expect(response).to have_http_status(:not_found)
      end

      it "handles multiple giftees in a batch gift scenario" do
        # Create another giftee for the same product
        second_giftee_purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: gifter_email, perceived_price_cents: 1000 },
            gift: { giftee_email: "second_giftee@example.com" }
          },
          buyer: buyer
        ).perform

        second_giftee_purchase.reload
        second_gp = second_giftee_purchase.gift_given&.giftee_purchase
        second_license = create(:license, link: bundle_product, purchase: second_gp, serial: "SECOND-KEY-789")

        # Verify both licenses work independently
        post :verify, params: { license_key: license.serial, product_id: bundle_product.external_id }
        expect(response).to have_http_status(:ok)

        post :verify, params: { license_key: second_license.serial, product_id: bundle_product.external_id }
        expect(response).to have_http_status(:ok)
      end
    end

    context "when handling partially refunded gifted purchases" do
      let!(:giftee_purchase) do
        sender_purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: gifter_email, perceived_price_cents: 1000 },
            gift: { giftee_email: giftee_email }
          },
          buyer: buyer
        ).perform

        sender_purchase.reload
        sender_purchase.gift_given&.giftee_purchase
      end

      let!(:license) { create(:license, link: bundle_product, purchase: giftee_purchase, serial: "REFUND-TEST-123") }

      it "continues to verify license after gifter purchase is refunded" do
        # Refund the gifter's purchase
        gifter_purchase = giftee_purchase.purchase_link
        gifter_purchase.update!(refunded: true)

        post :verify, params: { license_key: license.serial, product_id: bundle_product.external_id }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("success" => true)
      end
    end

    context "when handling disabled licenses for gifted purchases" do
      let!(:giftee_purchase) do
        sender_purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: gifter_email, perceived_price_cents: 1000 },
            gift: { giftee_email: giftee_email }
          },
          buyer: buyer
        ).perform

        sender_purchase.reload
        sender_purchase.gift_given&.giftee_purchase
      end

      let!(:license) { create(:license, link: bundle_product, purchase: giftee_purchase, serial: "DISABLED-TEST-123") }

      it "returns error for disabled gifted license" do
        license.disable!

        post :verify, params: { license_key: license.serial, product_id: bundle_product.external_id }
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to include("success" => false, "message" => "This license key has been disabled.")
      end
    end
  end
end