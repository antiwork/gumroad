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

# No HTTP: the domain index is the case under test, and the registered host is stubbed out.
describe CreateStripeApplePayDomainWorker do
  before do
    @user = create(:user, username: "sampleusername")
    allow(Subdomain).to receive(:from_username).and_return("sampleusername.gumroad.dev")
    allow(Rails.env).to receive(:test?).and_return(false)
  end

  it "leaves an existing registration alone when the host belongs to a released username" do
    StripeApplePayDomain.create!(
      user: create(:user, username: "reusedseller"),
      domain: "sampleusername.gumroad.dev",
      stripe_id: "apwc_existing"
    )
    expect(Stripe::ApplePayDomain).not_to receive(:create)

    expect { described_class.new.perform(@user.id) }.not_to raise_error
    expect(StripeApplePayDomain.where(domain: "sampleusername.gumroad.dev").pluck(:user_id))
      .to eq([User.find_by(username: "reusedseller").id])
  end

  it "treats a row inserted by a concurrent worker as already registered" do
    allow(Stripe::ApplePayDomain).to receive(:create).and_return(double(id: "apwc_race"))
    allow(StripeApplePayDomain).to receive(:create).and_raise(ActiveRecord::RecordNotUnique)

    expect { described_class.new.perform(@user.id) }.not_to raise_error
  end
end
