# frozen_string_literal: true

require "rails_helper"

RSpec.describe PurchasesController, type: :controller do
  describe "Additional edge cases for gifted bundle purchase receipts" do
    render_views
    before { stub_const("ObfuscateIds::CIPHER_KEY", "spec-test-key") }

    let(:seller) { create(:user) }
    let(:buyer) { create(:user) }
    let(:bundle_product) { create(:bundle, user: seller, price_cents: 2000) }
    let(:child_product1) { create(:product, user: seller, price_cents: 500) }
    let(:child_product2) { create(:product, user: seller, price_cents: 800) }

    before do
      bundle_product.links << [child_product1, child_product2]
    end

    context "when accessing receipt for gifted bundle with multiple products" do
      let(:gifter_email) { "bundle_gifter@example.com" }
      let(:giftee_email) { "bundle_giftee@example.com" }

      let!(:gifter_purchase) do
        purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: gifter_email, perceived_price_cents: 2000 },
            gift: { giftee_email: giftee_email }
          },
          buyer: buyer
        ).perform
        purchase.reload
        purchase
      end

      let!(:giftee_purchase) { gifter_purchase.gift_given&.giftee_purchase }

      it "generates receipt for giftee when accessed with gifter email" do
        expect(giftee_purchase).to be_present

        get :receipt, params: { id: gifter_purchase.external_id, email: gifter_email }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(giftee_email)
      end

      it "handles receipt generation when bundle has no child products" do
        empty_bundle = create(:bundle, user: seller, price_cents: 1500)
        empty_purchase, _ = Purchase::CreateService.new(
          product: empty_bundle,
          params: {
            is_gift: true,
            purchase: { email: "empty_gifter@example.com", perceived_price_cents: 1500 },
            gift: { giftee_email: "empty_giftee@example.com" }
          },
          buyer: buyer
        ).perform

        empty_purchase.reload
        empty_giftee = empty_purchase.gift_given&.giftee_purchase

        get :receipt, params: { id: empty_purchase.external_id, email: "empty_gifter@example.com" }
        expect(response).to have_http_status(:ok)
      end

      it "handles case-insensitive email comparison with whitespace" do
        get :receipt, params: { id: gifter_purchase.external_id, email: " #{gifter_email.upcase}  " }
        expect(response).to have_http_status(:ok)
      end

      it "rejects receipt access with incorrect email" do
        get :receipt, params: { id: gifter_purchase.external_id, email: "wrong@example.com" }
        expect(response).to redirect_to(confirm_receipt_email_purchase_path(gifter_purchase.external_id))
        expect(flash[:alert]).to eq("Wrong email. Please try again.")
      end
    end

    context "when handling receipts for multiple gift recipients from same gifter" do
      let(:gifter_email) { "multi_gifter@example.com" }
      let(:recipients) { ["recipient1@example.com", "recipient2@example.com", "recipient3@example.com"] }

      let!(:gift_purchases) do
        recipients.map do |recipient_email|
          purchase, _ = Purchase::CreateService.new(
            product: bundle_product,
            params: {
              is_gift: true,
              purchase: { email: gifter_email, perceived_price_cents: 2000 },
              gift: { giftee_email: recipient_email }
            },
            buyer: buyer
          ).perform
          purchase.reload
          purchase
        end
      end

      it "generates correct receipt for each gift purchase" do
        gift_purchases.each_with_index do |purchase, index|
          giftee_purchase = purchase.gift_given&.giftee_purchase
          expect(giftee_purchase).to be_present

          get :receipt, params: { id: purchase.external_id, email: gifter_email }
          expect(response).to have_http_status(:ok)
          expect(response.body).to include(recipients[index])
        end
      end
    end

    context "when handling receipts for refunded gifted purchases" do
      let!(:refunded_purchase) do
        purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: "refund_gifter@example.com", perceived_price_cents: 2000 },
            gift: { giftee_email: "refund_giftee@example.com" }
          },
          buyer: buyer
        ).perform
        purchase.reload
        purchase.update!(refunded: true)
        purchase
      end

      it "still generates receipt for refunded gift purchase" do
        get :receipt, params: { id: refunded_purchase.external_id, email: "refund_gifter@example.com" }
        expect(response).to have_http_status(:ok)
      end
    end

    context "when handling receipts for chargebacked gifted purchases" do
      let!(:chargebacked_purchase) do
        purchase, _ = Purchase::CreateService.new(
          product: bundle_product,
          params: {
            is_gift: true,
            purchase: { email: "chargeback_gifter@example.com", perceived_price_cents: 2000 },
            gift: { giftee_email: "chargeback_giftee@example.com" }
          },
          buyer: buyer
        ).perform
        purchase.reload
        purchase.update!(chargebacked: true)
        purchase
      end

      it "generates receipt for chargebacked gift purchase" do
        get :receipt, params: { id: chargebacked_purchase.external_id, email: "chargeback_gifter@example.com" }
        expect(response).to have_http_status(:ok)
      end
    end
  end
end