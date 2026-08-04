# frozen_string_literal: true

require "spec_helper"

describe Onetime::ReconcileStuckStripeDisputes do
  let(:purchase) { create(:purchase, chargeback_date: 1.year.ago) }
  let!(:dispute) do
    create(:dispute, purchase:, state: "formalized",
                     formalized_side_effects_finished_at: 1.year.ago,
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

      expect(result[:stats][:would_book_won]).to eq(1)
    end
  end

  describe "reading the verdict from Stripe" do
    it "books a won dispute and reverses the buyer's chargeback" do
      stub_stripe(stripe_dispute(status: "won"))

      expect do
        described_class.process(dry_run: false)
      end.to change { Credit.count }.by(1)

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
      expect(result[:stats][:refused_not_found_on_account_tried]).to eq(1)
    end

    it "refuses a dispute carrying no processor id" do
      dispute.update!(charge_processor_dispute_id: nil)

      result = described_class.process(dry_run: false)

      expect(result[:stats][:refused_no_processor_dispute_id]).to eq(1)
    end

    # The seller-side debit is written by the FORMALIZED side effects. Without it there is no
    # debit to reverse, so a won booking would credit money we never took.
    it "refuses a dispute that never formalized internally, without calling Stripe" do
      dispute.update!(state: "created")
      expect(Stripe::Dispute).to_not receive(:retrieve)

      result = described_class.process(dry_run: false)

      expect(result[:stats][:refused_not_formalized_internally]).to eq(1)
      expect(dispute.reload.state).to eq("created")
      expect(purchase.reload.chargeback_reversed).to be_falsey
    end

    it "refuses a dispute whose formalization never finished" do
      dispute.update!(formalized_side_effects_finished_at: nil)
      stub_stripe(stripe_dispute(status: "won"))

      result = described_class.process(dry_run: false)

      expect(result[:stats][:refused_formalization_incomplete]).to eq(1)
      expect(dispute.reload.state).to eq("formalized")
    end

    # A won destination charge settles through funds_reinstated, which moves real money to the
    # creator's Stripe account. Booking only our side would credit them on paper with nothing
    # behind it.
    it "refuses a Gumroad-managed Stripe (destination) charge" do
      merchant_account = create(:merchant_account)
      expect(merchant_account.is_a_gumroad_managed_stripe_account?).to eq(true)
      purchase.update!(merchant_account:)
      stub_stripe(stripe_dispute(status: "won"))

      result = described_class.process(dry_run: false)

      expect(result[:stats][:refused_destination_charge_needs_manual_repair]).to eq(1)
      expect(dispute.reload.state).to eq("formalized")
      expect(purchase.reload.chargeback_reversed).to be_falsey
    end

    # Gumroad's own platform account is also "Gumroad-managed", but it settles the ordinary direct
    # charges that are the bulk of this cohort. Refusing those would make the script a no-op.
    it "does not mistake Gumroad's platform account for a destination charge" do
      expect(purchase.merchant_account.is_managed_by_gumroad?).to eq(true)
      expect(purchase.merchant_account.is_a_gumroad_managed_stripe_account?).to eq(true)
      stub_stripe(stripe_dispute(status: "won"))

      result = described_class.process(dry_run: false)

      expect(result[:stats][:refused_destination_charge_needs_manual_repair]).to eq(0)
      expect(dispute.reload.state).to eq("won")
    end

    it "records a per-row failure instead of aborting the whole run" do
      other_purchase = create(:purchase, chargeback_date: 1.year.ago)
      create(:dispute, purchase: other_purchase, state: "formalized",
                       formalized_side_effects_finished_at: 1.year.ago,
                       charge_processor_id: StripeChargeProcessor.charge_processor_id,
                       charge_processor_dispute_id: "dp_other")
      stub_stripe(stripe_dispute(status: "won"))
      allow_any_instance_of(Purchase).to receive(:handle_event_dispute_won!).and_wrap_original do |method, *args|
        raise "boom" if method.receiver.id == purchase.id
        method.call(*args)
      end

      result = described_class.process(dry_run: false)

      expect(result[:stats][:scanned]).to eq(2)
      expect(result[:stats][:failed_won]).to eq(1)
      expect(result[:stats][:booked_won]).to eq(1)
    end
  end

  describe "resolving the Stripe account for a connected Charge" do
    let(:connect_merchant_account) { create(:merchant_account_stripe_connect) }
    let(:charge) { create(:charge, merchant_account: connect_merchant_account) }
    # The purchase's own merchant_account is nil, the shape flagged by Greptile on #6852: the
    # Charge is on a real connected account but the purchase row never got one assigned.
    let!(:charge_dispute) do
      create(:dispute, charge:, purchase: nil, state: "formalized",
                       formalized_side_effects_finished_at: 1.year.ago,
                       charge_processor_id: StripeChargeProcessor.charge_processor_id,
                       charge_processor_dispute_id: "dp_connected")
    end

    before do
      charge.purchases << create(:purchase, price_cents: 0, merchant_account: nil, chargeback_date: 1.year.ago)
      charge.update!(disputed_at: 1.year.ago)
    end

    it "scopes the Stripe retrieval to the Charge's connected account, not the purchase's" do
      expect(Stripe::Dispute).to receive(:retrieve)
        .with(hash_including(id: "dp_connected"), { stripe_account: connect_merchant_account.charge_processor_merchant_id })
        .and_return(stripe_dispute(status: "won", id: "dp_connected"))

      result = described_class.process(dry_run: false, dispute_ids: [charge_dispute.id])

      expect(result[:stats][:booked_won]).to eq(1)
      expect(charge_dispute.reload.state).to eq("won")
    end
  end

  describe "scoping" do
    it "only touches the ids it was given" do
      other = create(:dispute, purchase: create(:purchase, chargeback_date: 1.year.ago),
                               state: "formalized",
                               formalized_side_effects_finished_at: 1.year.ago,
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
