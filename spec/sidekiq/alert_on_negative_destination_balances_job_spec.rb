# frozen_string_literal: true

require "spec_helper"

describe AlertOnNegativeDestinationBalancesJob do
  let(:seller) { create(:user) }
  let(:merchant_account) do
    # A unique processor id: the factory default collides with the Gumroad fixture rows through a
    # uniqueness validation, and the collision moves between examples with the id sequence.
    create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                              currency: Currency::PHP, country: "PH")
  end

  # The reported shape: `amount_cents` reads clean so the seller's USD balance looks whole, while
  # `holding_amount_cents` carries the FX residue that comes off the local-currency wire.
  def residue_row(cents, date: Date.today - 1)
    create(:balance, user: seller, merchant_account:, date:,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: cents)
  end

  # Payability is read off the user, so the seller needs enough USD to clear their own minimum.
  def make_payable
    create(:balance, user: seller, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                     date: Date.today - 1, amount_cents: 200_00, holding_amount_cents: 200_00)
    seller.reload
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "reports a payable seller whose destination ledger nets negative" do
    residue_row(-728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, message|
      expect(room).to eq("payouts")
      expect(subject).to eq("Negative destination balances")
      expect(message).to include("1 payable seller has a negative destination ledger")
      expect(message).to include(seller.email)
      expect(message).to include("-72850 php cents")
      expect(message).to include(merchant_account.charge_processor_merchant_id)
    end
  end

  it "stays silent when negative rows exist but nobody is payable, because nothing is firing yet" do
    residue_row(-728_50)
    seller.reload

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "counts the not-yet-payable sellers alongside a payable one, so the reader sees what is queued behind it" do
    residue_row(-728_50)
    make_payable

    other = create(:user)
    other_account = create(:merchant_account, user: other, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                              charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                              currency: Currency::PHP, country: "PH")
    create(:balance, user: other, merchant_account: other_account, date: Date.today - 1,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("1 payable seller has")
      expect(message).to include("1 more carry a negative destination ledger but are under their payout minimum")
      expect(message).to include(seller.email)
      expect(message).not_to include(other.email)
    end
  end

  it "stays silent for a negative destination total matched by a negative USD ledger, which is refund netting the payout handles" do
    create(:balance, user: seller, merchant_account:, date: Date.today - 1,
                     amount_cents: -728_50, holding_currency: Currency::PHP, holding_amount_cents: -728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "stays silent when no balance is negative" do
    create(:balance, user: seller, merchant_account:, date: Date.today - 1,
                     holding_currency: Currency::PHP, holding_amount_cents: 100_00)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "does not report a negative row that healthy rows on the same account outweigh, because the payout guard lets that set through" do
    residue_row(-100_00)
    create(:balance, user: seller, merchant_account:, date: Date.today - 2,
                     holding_currency: Currency::PHP, holding_amount_cents: 500_00)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "does not report a suspended seller, whose payouts are not running anyway" do
    residue_row(-728_50)
    make_payable
    seller.update!(user_risk_state: "suspended_for_fraud")

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a residue row on a retired merchant account, marking it, because the payout run still takes that row" do
    residue_row(-728_50)
    make_payable
    merchant_account.update!(deleted_at: Time.current)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include("[RETIRED account]")
    end
  end

  it "sums several residue rows on one account into a single line rather than one per row" do
    residue_row(-300_00, date: Date.today - 3)
    residue_row(-428_50, date: Date.today - 2)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("1 payable seller has")
      expect(message).to include("-72850 php cents across 2 balances")
    end
  end

  it "tells the reader how to repair a line, in the order that does not make it worse" do
    residue_row(-728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("top up the Connect account first, then zero the row")
    end
  end
end
