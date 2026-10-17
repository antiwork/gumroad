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
    let(:unsupported_claims) { /stripe_apple_pay_domains|wallet|Stripe error|Re-running|registers the domain/i }

    it "notifies with the user and enqueued domain without asserting a cause or recovery" do
      message = nil
      allow(ErrorNotifier).to receive(:notify) { |notified| message = notified }

      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [1234, "seller.example.com"] },
        StandardError.new("synthetic failure")
      )

      expect(message).to eq(
        "CreateStripeApplePayDomainWorker exhausted Sidekiq retries for user 1234 (domain seller.example.com). " \
        "Inspect the dead job for the error and the registration state before retrying."
      )
      expect(message).not_to match(unsupported_claims)
    end

    it "reports the domain as unknown when the enqueued job carried none" do
      message = nil
      allow(ErrorNotifier).to receive(:notify) { |notified| message = notified }

      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [1234] },
        StandardError.new("synthetic failure")
      )

      expect(message).to eq(
        "CreateStripeApplePayDomainWorker exhausted Sidekiq retries for user 1234 (domain unknown). " \
        "Inspect the dead job for the error and the registration state before retrying."
      )
      expect(message).not_to match(unsupported_claims)
    end
  end
end
