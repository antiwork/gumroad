# frozen_string_literal: true

require "test_helper"

class CreateStripeApplePayDomainWorkerTest < ActiveSupport::TestCase
  self.described_class = CreateStripeApplePayDomainWorker
  self.rspec_metadata = { vcr: true }


  context_ CreateStripeApplePayDomainWorker, :vcr do
  context_ "#perform" do
      before do
        @user = create(:user, username: "sampleusername")
        allow(Subdomain).to receive(:from_username).and_return("sampleusername.gumroad.dev")
        allow(Rails.env).to receive(:test?).and_return(false)
      end

  test "creates Stripe::ApplePayDomain and persists StripeApplePayDomain" do
        described_class.new.perform(@user.id)
        expect(StripeApplePayDomain.last.stripe_id).to match(/apwc/)
        expect(StripeApplePayDomain.last.domain).to eq("sampleusername.gumroad.dev")
        expect(StripeApplePayDomain.last.user_id).to eq(@user.id)
      end
    end
  end
end
