# frozen_string_literal: true

describe CreateStripeApplePayDomainWorker, :vcr do
  describe "#perform" do
    before do
      @user = create(:user, username: "sampleusername")
      allow(Subdomain).to receive(:from_username).and_return("sampleusername.gumroad.dev")
      allow(Rails.env).to receive(:test?).and_return(false)
    end

    it "creates Stripe::ApplePayDomain and persists StripeApplePayDomain" do
      described_class.new.perform(@user.id)
      expect(StripeApplePayDomain.last.stripe_id).to match(/apwc/)
      expect(StripeApplePayDomain.last.domain).to eq("sampleusername.gumroad.dev")
      expect(StripeApplePayDomain.last.user_id).to eq(@user.id)
    end
  end

  describe "when the retries are exhausted" do
    it "notifies with the seller and domain that never got registered" do
      expect(ErrorNotifier).to receive(:notify).with(
        /user 1234.*sampleusername\.gumroad\.dev.*wallet/m
      )

      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [1234, "sampleusername.gumroad.dev"] },
        StandardError.new("Stripe is down")
      )
    end

    it "still notifies when the enqueued job carried no domain" do
      expect(ErrorNotifier).to receive(:notify).with(/user 1234.*unknown/m)

      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [1234] },
        StandardError.new("Stripe is down")
      )
    end
  end
end
