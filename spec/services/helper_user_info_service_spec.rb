# frozen_string_literal: true

require "spec_helper"

describe HelperUserInfoService do
  include Rails.application.routes.url_helpers

  let(:user) { create(:user, email: "user@example.com") }

  describe "#user_info" do
    let(:service) { described_class.new(email: user.email) }

    it "retrieves user info" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(2250)

      result = service.user_info
      expect(result[:prompt]).to include("User ID: #{user.id}")
      expect(result[:prompt]).to include("User Name: #{user.name}")
      expect(result[:prompt]).to include("User Email: #{user.email}")
      expect(result[:prompt]).to include("Account Status: Active")
      expect(result[:prompt]).to include("Total Earnings Since Joining: $22.50")
      expect(result[:metadata]).to eq({
                                        name: user.name,
                                        email: user.email,
                                        value: 2250,
                                        links: {
                                          "Admin (user)": "http://app.test.gumroad.com:31337/admin/users/#{user.id}",
                                          "Admin (purchases)": "http://app.test.gumroad.com:31337/admin/search_purchases?query=#{CGI.escape(user.email)}",
                                          "Impersonate": "http://app.test.gumroad.com:31337/admin/helper_actions/impersonate/#{user.external_id}"
                                        }
                                      })
    end

    context "value calculation" do
      let(:product) { create(:product, user:, price_cents: 100_00) }

      it "returns the higher value between lifetime sales and last-90-day purchases" do
        # Bought $10.00 of products in the last 90 days.
        create(:purchase, purchaser: user, price_cents: 10_00, created_at: 95.days.ago)
        create(:purchase, purchaser: user, price_cents: 10_00, created_at: 1.day.ago)
        index_model_records(Purchase)

        expect(service.user_info[:metadata][:value]).to eq(10_00)

        # Sold $100.00 of products, before fees.
        sale = create(:purchase, link: product, price_cents: 100_00, created_at: 30.days.ago)
        index_model_records(Purchase)

        expect(service.user_info[:metadata][:value]).to eq(sale.payment_cents)
      end
    end

    context "when user is not found" do
      let(:service) { described_class.new(email: "inexistent@example.com") }

      it "returns empty prompt and metadata" do
        result = service.user_info
        expect(result[:prompt]).to eq("")
        expect(result[:metadata]).to eq({})
      end
    end

    context "with recent purchase" do
      let(:service) { HelperUserInfoService.new(email: user.email) }

      it "includes recent purchase info" do
        product = create(:product)
        purchase = create(:purchase, purchaser: user, link: product, price_cents: 1_00, created_at: 1.day.ago)
        result = service.user_info

        expect(result[:prompt]).to include("Successful Purchase: #{purchase.email} bought #{product.name} for $1 on #{purchase.created_at.to_fs(:formatted_date_full_month)}")
        expect(result[:prompt]).to include("Product URL: #{product.long_url}")
        expect(result[:prompt]).to include("Creator Support Email: #{purchase.seller.support_email || purchase.seller.form_email}")
        expect(result[:prompt]).to include("Receipt URL: #{receipt_purchase_url(purchase.external_id, email: purchase.email, host: DOMAIN)}")
      end
    end

    context "when user has a Stripe Connect account" do
      it "includes the stripe_connect_account_id in links" do
        merchant_account = create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id)
        user_with_stripe = merchant_account.user
        service = described_class.new(email: user_with_stripe.email)

        result = service.user_info
        expect(result[:metadata][:links]["View Stripe account"]).to eq("http://app.test.gumroad.com:31337/admin/helper_actions/stripe_dashboard/#{user_with_stripe.external_id}")
      end
    end

    context "when there's a failed purchase" do
      it "includes failed purchase info" do
        product = create(:product)
        failed_purchase = create(:purchase, purchase_state: "failed", purchaser: user, link: product, price_cents: 1_00, created_at: 1.day.ago)
        result = described_class.new(email: user.email).user_info
        expect(result[:prompt]).to include("Failed Purchase Attempt: #{failed_purchase.email} tried to buy #{product.name} for $1 on #{failed_purchase.created_at.to_fs(:formatted_date_full_month)}")
        expect(result[:prompt]).to include("Error: #{failed_purchase.formatted_error_code}")
      end
    end

    context "when purchase has a refund policy" do
      it "includes refund policy info" do
        product = create(:product)
        purchase = create(:purchase, purchaser: user, link: product, created_at: 1.day.ago)
        purchase.create_purchase_refund_policy!(
          title: "This is a product-level refund policy",
          fine_print: "This is the fine print of the refund policy."
        )
        result = described_class.new(email: user.email).user_info
        expect(result[:prompt]).to include("Refund Policy: This is the fine print of the refund policy.")
      end
    end

    context "when purchase has a license key" do
      it "includes license key info" do
        product = create(:product, is_licensed: true)
        purchase = create(:purchase, purchaser: user, link: product, created_at: 1.day.ago)
        license = create(:license, purchase: purchase)
        result = described_class.new(email: user.email).user_info
        expect(result[:prompt]).to include("License Key: #{license.serial}")
      end
    end
  end
end
