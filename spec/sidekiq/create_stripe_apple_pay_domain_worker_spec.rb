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

    # No HTTP from here on: the domain index is the case under test, and Stripe is stubbed out.
    context "when the host already has a row", vcr: false do
      before { allow(Stripe::ApplePayDomain).to receive(:retrieve) { |stripe_id| double(id: stripe_id) } }

      it "takes the registration over from the account that used to hold the username" do
        previous_owner = create(:user, username: "reusedseller")
        StripeApplePayDomain.create!(
          user: previous_owner,
          domain: "sampleusername.gumroad.dev",
          stripe_id: "apwc_existing"
        )
        expect(Stripe::ApplePayDomain).not_to receive(:create)

        expect { described_class.new.perform(@user.id) }.not_to raise_error
        expect(StripeApplePayDomain.find_by(domain: "sampleusername.gumroad.dev").user_id).to eq(@user.id)
      end

      it "leaves its own registration untouched" do
        StripeApplePayDomain.create!(user: @user, domain: "sampleusername.gumroad.dev", stripe_id: "apwc_own")
        expect(Stripe::ApplePayDomain).not_to receive(:create)

        expect { described_class.new.perform(@user.id) }.not_to raise_error
        expect(StripeApplePayDomain.find_by(domain: "sampleusername.gumroad.dev").stripe_id).to eq("apwc_own")
      end

      it "keeps the host registered when the previous owner's delete job runs afterwards" do
        previous_owner = create(:user, username: "reusedseller")
        StripeApplePayDomain.create!(
          user: previous_owner,
          domain: "sampleusername.gumroad.dev",
          stripe_id: "apwc_existing"
        )

        described_class.new.perform(@user.id)

        expect(Stripe::ApplePayDomain).not_to receive(:delete)
        DeleteStripeApplePayDomainWorker.new.perform(previous_owner.id, "sampleusername.gumroad.dev")

        expect(StripeApplePayDomain.find_by(domain: "sampleusername.gumroad.dev")&.user_id).to eq(@user.id)
      end

      it "raises for a retry and leaves the row alone when Stripe does not say the registration is gone" do
        previous_owner = create(:user, username: "reusedseller")
        StripeApplePayDomain.create!(user: previous_owner, domain: "sampleusername.gumroad.dev", stripe_id: "apwc_existing")
        expect(Stripe::ApplePayDomain).not_to receive(:create)

        [
          Stripe::APIConnectionError.new("Timed out connecting to Stripe"),
          Stripe::InvalidRequestError.new("Invalid request", "domain", http_status: 400, code: "parameter_invalid"),
        ].each do |error|
          allow(Stripe::ApplePayDomain).to receive(:retrieve).with("apwc_existing").and_raise(error)

          expect { described_class.new.perform(@user.id) }.to raise_error(error.class)
          expect(StripeApplePayDomain.where(domain: "sampleusername.gumroad.dev").pluck(:user_id, :stripe_id))
            .to eq([[previous_owner.id, "apwc_existing"]])
        end
      end
    end

    context "when a concurrent create inserts the host's row first", vcr: false do
      before do
        concurrent_holder = create(:user, username: "concurrentseller")
        allow(Stripe::ApplePayDomain).to receive(:retrieve) { |stripe_id| double(id: stripe_id) }
        allow(Stripe::ApplePayDomain).to receive(:create) do
          @concurrent_row = StripeApplePayDomain.create!(
            user: concurrent_holder,
            domain: "sampleusername.gumroad.dev",
            stripe_id: "apwc_concurrent"
          )
          double(id: "apwc_own")
        end
      end

      it "claims that row for this account" do
        expect { described_class.new.perform(@user.id) }.not_to raise_error
        expect(StripeApplePayDomain.find_by(domain: "sampleusername.gumroad.dev").user_id).to eq(@user.id)
      end

      it "raises for a retry when a delete has removed that row before it can be claimed" do
        allow(StripeApplePayDomain).to receive(:create).and_wrap_original do |original, *args|
          original.call(*args)
        ensure
          @concurrent_row.destroy!
        end

        expect { described_class.new.perform(@user.id) }.to raise_error(ActiveRecord::RecordNotUnique)
      end

      it "raises for a retry when Stripe no longer has that row's registration" do
        allow(Stripe::ApplePayDomain).to receive(:retrieve).with("apwc_concurrent").and_raise(
          Stripe::InvalidRequestError.new("No such apple_pay_domain: 'apwc_concurrent'", "domain", http_status: 404, code: "resource_missing")
        )

        expect { described_class.new.perform(@user.id) }.to raise_error(ActiveRecord::RecordNotUnique)
        expect(StripeApplePayDomain.exists?(domain: "sampleusername.gumroad.dev")).to be(false)
      end
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
