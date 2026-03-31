# frozen_string_literal: true

require "spec_helper"

describe Link do
  describe "#enforce_two_factor_authentication_for_new_sellers!" do
    let(:user) { create(:user) }
    let(:product) { create(:product_with_pdf_file, purchase_disabled_at: Time.current, user: user) }

    before do
      Feature.activate(:require_2fa_before_selling)
      allow(product).to receive(:enforce_shipping_destinations_presence!)
      allow(product).to receive(:enforce_user_email_confirmation!)
      allow(product).to receive(:enforce_merchant_account_exits_for_new_users!)
    end

    after do
      Feature.deactivate(:require_2fa_before_selling)
    end

    context "when the seller has no TOTP set up and no published products" do
      it "raises a Link::LinkInvalid error" do
        expect do
          product.publish!
        end.to raise_error(Link::LinkInvalid, /You must set up two-factor authentication/)
        expect(product.reload.purchase_disabled_at).to_not be(nil)
      end
    end

    context "when the seller has TOTP enabled" do
      before do
        create(:totp_credential, :confirmed, user: user)
      end

      it "publishes the product" do
        expect do
          product.publish!
        end.to change { product.reload.purchase_disabled_at }.to(nil)
      end
    end

    context "when the seller already has a published product" do
      before do
        create(:product, user: user, purchase_disabled_at: nil, draft: false)
      end

      it "publishes the product without requiring TOTP" do
        expect do
          product.publish!
        end.to change { product.reload.purchase_disabled_at }.to(nil)
      end
    end

    context "when the feature flag is disabled" do
      before do
        Feature.deactivate(:require_2fa_before_selling)
      end

      it "publishes the product without requiring TOTP" do
        expect do
          product.publish!
        end.to change { product.reload.purchase_disabled_at }.to(nil)
      end
    end
  end
end
