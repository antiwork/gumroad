# frozen_string_literal: true

require "spec_helper"

describe LiftPlatformStripePauseJob do
  let(:seller) { create(:user) }
  let!(:merchant_account) do
    create(:merchant_account, user: seller,
                              charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_pauselift")
  end

  # Built as a real `Stripe::StripeObject`: it exposes `[]` but not `dig`, which a Hash stub would hide.
  def stripe_account(charges_paused: true, payouts_paused: false, disabled_reason: "platform_paused", past_due: [], transfers: "inactive")
    Stripe::StripeObject.construct_from(
      id: "acct_pauselift",
      risk_controls: { charges: { pause_requested: charges_paused }, payouts: { pause_requested: payouts_paused } },
      requirements: { disabled_reason:, past_due: },
      future_requirements: { past_due: [] },
      capabilities: { transfers: }
    )
  end

  def stub_stripe(account)
    allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(account)
    allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
  end

  def notes
    seller.comments.with_type_note.where(author_name: described_class::AUTHOR_NAME)
  end

  before { seller.mark_compliant!(author_id: create(:admin_user).id) }

  describe "#perform" do
    it "lifts the charges pause and records the before and after state" do
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).to have_received(:update).with("acct_pauselift", risk_controls: { charges: { pause_requested: false } })
      expect(notes.count).to eq(1)
      expect(notes.last.content).to include("Lifted the platform Stripe pause on acct_pauselift")
      expect(notes.last.content).to include("charges paused: true").and include("transfers: \"inactive\"")
      expect(notes.last.content).to include("charges paused: false").and include("transfers: \"active\"")
    end

    it "does nothing when the account has no platform pause" do
      stub_stripe(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:update)
      expect(notes).to be_empty
    end

    {
      "both charges and payouts are paused" => { payouts_paused: true },
      "the reason is a rejection" => { disabled_reason: "rejected.fraud" },
      "the reason is not platform_paused" => { disabled_reason: "requirements.past_due" },
      "requirements are past due" => { past_due: ["individual.verification.document"] },
    }.each do |description, attributes|
      it "leaves the pause and adds a note when #{description}" do
        stub_stripe(stripe_account(**attributes))

        expect { described_class.new.perform(seller.id) }.not_to raise_error

        expect(Stripe::Account).not_to have_received(:update)
        expect(notes.count).to eq(1)
        expect(notes.last.content).to start_with("Left the platform Stripe pause on acct_pauselift")
      end
    end

    it "leaves a pause on future-requirements past due" do
      account = stripe_account
      account["future_requirements"] = Stripe::StripeObject.construct_from(past_due: ["company.tax_id"])
      stub_stripe(account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:update)
      expect(notes.last.content).to include("past-due")
    end

    it "does not act on an account that is no longer compliant" do
      seller.update!(user_risk_state: "flagged_for_fraud")
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    it "does not touch a seller's own connected Stripe account" do
      merchant_account.update!(json_data: { "meta" => { "stripe_connect" => "true" } })
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    it "does not touch a deleted merchant account" do
      merchant_account.mark_deleted!
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    it "notes a rejected Stripe request and carries on without raising" do
      allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::InvalidRequestError.new("No such account", nil))

      expect { described_class.new.perform(seller.id) }.not_to raise_error

      expect(notes.last.content).to include("Could not lift the platform Stripe pause on acct_pauselift: No such account")
    end

    it "lets a temporary Stripe failure raise so Sidekiq retries" do
      allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("timeout"))

      expect { described_class.new.perform(seller.id) }.to raise_error(Stripe::APIConnectionError)
    end
  end

  describe "enqueueing" do
    let(:other_seller) { create(:user) }

    it "is enqueued once the compliant transition commits" do
      expect do
        other_seller.mark_compliant!(author_id: create(:admin_user).id)
      end.to change { described_class.jobs.size }.by(1)
      expect(described_class.jobs.last["args"]).to eq([other_seller.id])
    end

    it "is not enqueued when the transition rolls back" do
      expect do
        User.transaction do
          other_seller.mark_compliant!(author_id: create(:admin_user).id)
          raise ActiveRecord::Rollback
        end
      end.not_to change { described_class.jobs.size }
    end

    it "is not enqueued for other risk states" do
      expect do
        other_seller.put_on_probation!(author_id: create(:admin_user).id)
      end.not_to change { described_class.jobs.size }
    end
  end
end
