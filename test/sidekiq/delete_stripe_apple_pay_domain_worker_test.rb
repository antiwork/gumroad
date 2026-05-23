# frozen_string_literal: true

require "test_helper"

class DeleteStripeApplePayDomainWorkerTest < ActiveSupport::TestCase
  self.described_class = DeleteStripeApplePayDomainWorker
  self.rspec_metadata = { vcr: true }


  context_ DeleteStripeApplePayDomainWorker, :vcr do
  context_ "#perform" do
      before do
        @user = create(:user)
        @domain = "sampleusername.gumroad.dev"
      end

  test "deletes StripeApplePayDomain record when record exists on Stripe" do
        response = Stripe::ApplePayDomain.create(domain_name: @domain)
        StripeApplePayDomain.create!(user_id: @user.id, domain: @domain, stripe_id: response.id)
        described_class.new.perform(@user.id, @domain)
        expect(StripeApplePayDomain.count).to eq(0)
      end

  test "deletes StripeApplePayDomain record when record doesn't exist on Stripe" do
        StripeApplePayDomain.create!(user_id: @user.id, domain: @domain, stripe_id: "random_stripe_id")
        described_class.new.perform(@user.id, @domain)
        expect(StripeApplePayDomain.count).to eq(0)
      end
    end
  end
end
