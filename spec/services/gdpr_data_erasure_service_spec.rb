# frozen_string_literal: true

require "spec_helper"

describe GdprDataErasureService do
  let(:user) { create(:user, email: "john@example.com", name: "John Doe", bio: "My bio", street_address: "123 Main St", city: "New York", state: "NY", zip_code: "10001", country: "US") }
  let(:admin) { create(:user, email: "admin@example.com", name: "Admin") }

  describe "#perform!" do
    it "anonymizes user PII" do
      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      user.reload
      expect(user.name).to eq("[deleted]")
      expect(user.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(user.bio).to be_nil
      expect(user.street_address).to be_nil
      expect(user.city).to be_nil
      expect(user.state).to be_nil
      expect(user.zip_code).to be_nil
      expect(user.country).to be_nil
      expect(user.current_sign_in_ip).to be_nil
      expect(user.last_sign_in_ip).to be_nil
      expect(user.account_created_ip).to be_nil
      expect(user.deleted_at).to be_present
    end

    it "anonymizes buyer purchases" do
      purchase = create(
        :free_purchase,
        purchaser: user,
        email: user.email,
        full_name: "John Doe",
        street_address: "123 Main St",
        ip_address: "127.0.0.1",
        browser_guid: "buyer-browser-guid",
      )

      described_class.new(user, performed_by: admin).perform!

      purchase.reload
      expect(purchase.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(purchase.full_name).to eq("[deleted]")
      expect(purchase.street_address).to be_nil
      expect(purchase.ip_address).to be_nil
      expect(purchase.browser_guid).to be_nil
    end

    it "anonymizes guest purchases using the original email address" do
      purchase = create(
        :free_purchase,
        purchaser: nil,
        email: user.email,
        full_name: "John Doe",
        street_address: "123 Main St",
        ip_address: "127.0.0.1",
        browser_guid: "guest-browser-guid",
      )

      described_class.new(user, performed_by: admin).perform!

      purchase.reload
      expect(purchase.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(purchase.full_name).to eq("[deleted]")
      expect(purchase.street_address).to be_nil
      expect(purchase.ip_address).to be_nil
      expect(purchase.browser_guid).to be_nil
    end

    it "anonymizes all of the user's carts and credit card records" do
      historical_cart = create(:cart, user:, email: user.email, ip_address: "127.0.0.2", browser_guid: "historical-browser-guid")
      historical_cart.mark_deleted!
      alive_cart = create(:cart, user:, email: user.email, ip_address: "127.0.0.1", browser_guid: "browser-guid")
      credit_card = CreditCard.create!(
        visual: "**** **** **** 4242",
        card_type: "visa",
        expiry_month: 12,
        expiry_year: 2030,
        stripe_customer_id: "cus_123",
        stripe_fingerprint: "fp_123",
        processor_payment_method_id: "pm_123",
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
      )
      user.update!(credit_card:)

      described_class.new(user, performed_by: admin).perform!

      [alive_cart, historical_cart].each do |cart|
        expect(cart.reload.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
        expect(cart.ip_address).to be_nil
        expect(cart.browser_guid).to be_nil
      end

      expect(credit_card.reload.card_type).to eq(GdprDataErasureService::ANONYMIZED_VALUE)
      expect(credit_card.visual).to eq(GdprDataErasureService::ANONYMIZED_VALUE)
      expect(credit_card.expiry_month).to be_nil
      expect(credit_card.expiry_year).to be_nil
      expect(credit_card.stripe_customer_id).to be_nil
      expect(credit_card.processor_payment_method_id).to be_nil
    end

    it "deletes the user's device records" do
      ios_device = create(:device, user:, token: "ios-device-token")
      android_device = create(:android_device, user:, token: "android-device-token")
      other_user_device = create(:device, token: "other-user-device-token")

      described_class.new(user, performed_by: admin).perform!

      expect(Device.exists?(ios_device.id)).to eq(false)
      expect(Device.exists?(android_device.id)).to eq(false)
      expect(Device.exists?(other_user_device.id)).to eq(true)
    end

    it "invokes the private subscription cancellation helper during erasure" do
      expect(user).to receive(:cancel_active_subscriptions!)

      described_class.new(user, performed_by: admin).perform!
    end

    it "deactivates the account and deletes products" do
      product = create(:product, user: user)

      described_class.new(user, performed_by: admin).perform!

      user.reload
      expect(user.deleted?).to eq(true)
      expect(product.reload.deleted?).to eq(true)
    end

    it "reports only alive products in the erasure summary" do
      create(:product, user: user)
      deleted_product = create(:product, user: user)
      deleted_product.delete!

      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:summary][:products_deleted]).to eq(1)
    end

    it "logs the erasure as a comment" do
      described_class.new(user, performed_by: admin).perform!

      comment = user.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(comment.content).to include("GDPR data erasure performed")
      expect(comment.content).to include("Transaction records retained")
    end

    it "returns external cleanup instructions" do
      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:summary][:external_cleanup_needed]).to include("Helper/Supabase (customer conversations)")
      expect(result[:summary][:external_cleanup_needed]).to include("Stripe (customer data)")
    end

    it "skips profile asset removal when transactional erasure work fails" do
      service = described_class.new(user, performed_by: admin)
      allow(service).to receive(:remove_profile_assets!)
      allow(service).to receive(:log_erasure!).and_raise(StandardError, "boom")

      result = service.perform!

      expect(result[:success]).to eq(false)
      expect(service).not_to have_received(:remove_profile_assets!)
    end
  end
end
