# frozen_string_literal: true

require "spec_helper"

describe Onetime::ReconcileStuckStripeDisputes do
  let(:purchase) { create(:purchase, chargeback_date: 1.year.ago) }
  let!(:dispute) do
    create(:dispute, purchase:, state: "formalized",
                     charge_processor_id: StripeChargeProcessor.charge_processor_id,
                     charge_processor_dispute_id: "dp_stuck")
  end

  def stripe_dispute(status:, balance_transactions: [{ amount: -1000 }, { amount: 1000 }], id: "dp_stuck")
    double(id:, status:, currency: "usd", amount: 1000, created: 1.year.ago.to_i,
           balance_transactions: balance_transactions.map { |bt| double(amount: bt[:amount]) })
  end

  def stub_stripe(stripe_double)
    allow(Stripe::Dispute).to receive(:retrieve).and_return(stripe_double)
  end

  describe "the dry-run default" do
    it "does not write when called without arguments" do
      stub_stripe(stripe_dispute(status: "won"))

      expect { described_class.process }.to_not change { dispute.reload.state }
    end

    it "does not write on the instance method either" do
      stub_stripe(stripe_dispute(status: "won"))

      expect { described_class.new.process }.to_not change { dispute.reload.state }
    end

    it "reports what it would book" do
      stub_stripe(stripe_dispute(status: "won"))

      result = described_class.process

      expect(result[:stats]["would_book_won".to_sym]).to eq(1)
    end
  end

  describe "reading the verdict from Stripe" do
    it "books a won dispute and reverses the buyer's chargeback" do
      stub_stripe(stripe_dispute(status: "won"))

      described_class.process(dry_run: false)

      expect(dispute.reload.state).to eq("won")
      expect(purchase.reload.chargeback_reversed).to eq(true)
    end

    it "books a lost dispute as lost rather than crediting the seller" do
      stub_stripe(stripe_dispute(status: "lost", balance_transactions: [{ amount: -1000 }]))

      described_class.process(dry_run: false)

      expect(dispute.reload.state).to eq("lost")
      expect(purchase.reload.chargeback_reversed).to be_falsey
    end

    it "leaves a dispute Stripe still considers open untouched" do
      stub_stripe(stripe_dispute(status: "needs_response"))

      described_class.process(dry_run: false)

      expect(dispute.reload.state).to eq("formalized")
    end
  end

  describe "refusals" do
    it "refuses a won dispute whose funds were never reinstated" do
      stub_stripe(stripe_dispute(status: "won", balance_transactions: [{ amount: -1000 }]))

      result = described_class.process(dry_run: false)

      expect(dispute.reload.state).to eq("formalized")
      expect(purchase.reload.chargeback_reversed).to be_falsey
      expect(result[:stats][:refused_won_without_reinstatement]).to eq(1)
    end

    it "refuses a dispute Stripe has never heard of" do
      allow(Stripe::Dispute).to receive(:retrieve)
        .and_raise(Stripe::InvalidRequestError.new("No such dispute: 'dp_stuck'", nil))

      result = described_class.process(dry_run: false)

      expect(dispute.reload.state).to eq("formalized")
      expect(result[:stats][:refused_unknown_to_stripe]).to eq(1)
    end

    it "refuses a dispute carrying no processor id" do
      dispute.update!(charge_processor_dispute_id: nil)

      result = described_class.process(dry_run: false)

      expect(result[:stats][:refused_no_processor_dispute_id]).to eq(1)
    end
  end

  describe "scoping" do
    it "only touches the ids it was given" do
      other = create(:dispute, purchase: create(:purchase, chargeback_date: 1.year.ago),
                               state: "formalized",
                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                               charge_processor_dispute_id: "dp_other")
      stub_stripe(stripe_dispute(status: "won"))

      described_class.process(dry_run: false, dispute_ids: [dispute.id])

      expect(dispute.reload.state).to eq("won")
      expect(other.reload.state).to eq("formalized")
    end

    it "ignores disputes that already reached a terminal state" do
      dispute.update!(state: "won")

      result = described_class.process(dry_run: false)

      expect(result[:stats][:scanned]).to eq(0)
    end
  end
end
