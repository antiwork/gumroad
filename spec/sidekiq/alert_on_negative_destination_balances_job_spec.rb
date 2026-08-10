# frozen_string_literal: true

require "spec_helper"

describe AlertOnNegativeDestinationBalancesJob do
  let(:seller) { create(:user) }
  # The scan reads balances the way the payout run does — up to the current cycle's cutoff — so
  # rows the examples expect it to see must be dated inside the cycle, not just in the past.
  let(:in_cycle_date) { User::PayoutSchedule.next_scheduled_payout_end_date - 1 }
  let(:merchant_account) do
    # A unique processor id: the factory default collides with the Gumroad fixture rows through a
    # uniqueness validation, and the collision moves between examples with the id sequence.
    create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                              currency: Currency::PHP, country: "PH")
  end

  # The reported shape: `amount_cents` reads clean so the seller's USD balance looks whole, while
  # `holding_amount_cents` carries the FX residue that comes off the local-currency wire.
  def residue_row(cents, date: in_cycle_date)
    create(:balance, user: seller, merchant_account:, date:,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: cents)
  end

  # Payability is read off the user, so the seller needs enough USD to clear their own minimum.
  def make_payable(cents = 200_00)
    create(:balance, user: seller, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                     date: in_cycle_date, amount_cents: cents, holding_amount_cents: cents)
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
    create(:balance, user: other, merchant_account: other_account, date: in_cycle_date,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("1 payable seller has")
      expect(message).to include("1 more carry a negative destination ledger but are under their payout minimum")
      expect(message).to include(seller.email)
      expect(message).not_to include(other.email)
    end
  end

  it "exposes the below-minimum tripped candidate's own balance ids for the consumer's off-scan TTL refresh" do
    residue_row(-728_50)
    make_payable

    other = create(:user)
    other_account = create(:merchant_account, user: other, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                              charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                              currency: Currency::PHP, country: "PH")
    other_row = create(:balance, user: other, merchant_account: other_account, date: in_cycle_date,
                                 amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)

    scan = described_class.scan

    expect(scan[:unreconciled_not_payable]).to contain_exactly(
      { merchant_account: other_account, balance_ids: [other_row.id] }
    )
  end

  it "carries post-cutoff rows in the below-minimum candidate's balance ids so funded credit past the cutoff keeps its TTL" do
    residue_row(-728_50)
    make_payable

    other = create(:user)
    other_account = create(:merchant_account, user: other, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                              charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                              currency: Currency::PHP, country: "PH")
    in_cycle_row = create(:balance, user: other, merchant_account: other_account, date: in_cycle_date,
                                    amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)
    post_cutoff_row = create(:balance, user: other, merchant_account: other_account,
                                       date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                                       amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: 25_00)

    scan = described_class.scan

    expect(scan[:unreconciled_not_payable]).to contain_exactly(
      { merchant_account: other_account, balance_ids: [in_cycle_row.id, post_cutoff_row.id] }
    )
  end

  it "stays silent for a negative destination total matched by a negative USD ledger, which is refund netting the payout handles" do
    create(:balance, user: seller, merchant_account:, date: in_cycle_date,
                     amount_cents: -728_50, holding_currency: Currency::PHP, holding_amount_cents: -728_50)
    # Enough USD that the seller clears their minimum past the netted debit — otherwise the
    # example is silent because nobody is payable, whether or not the netting filter exists.
    make_payable(1_000_00)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "stays silent for a seller-owned Stripe Connect account, which Stripe pays out itself" do
    connect_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                                currency: Currency::PHP, country: "PH")
    connect_account.update!(meta: { stripe_connect: "true" })
    create(:balance, user: seller, merchant_account: connect_account, date: in_cycle_date,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "stays silent when no balance is negative" do
    create(:balance, user: seller, merchant_account:, date: in_cycle_date,
                     holding_currency: Currency::PHP, holding_amount_cents: 100_00)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "does not treat a seller as payable on a post-cutoff USD credit the payout run cannot see yet" do
    residue_row(-728_50)
    make_payable(5_00) # below the $10 default minimum through the cutoff
    create(:balance, user: seller, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                     date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                     amount_cents: 500_00, holding_amount_cents: 500_00)
    seller.reload

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include("[post-cutoff — instant payout paths only until the cycle rolls]")
    end
  end

  it "stays silent when the seller is under minimum on both the cycle window and the whole ledger" do
    residue_row(-728_50)
    make_payable(5_00) # below the $10 default minimum on either window — no post-cutoff credit at all
    seller.reload

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a seller whose accounts straddle a scan batch boundary" do
    # Two merchant accounts on one seller, with the batch cut between them: cursoring on user_id
    # alone would advance past the seller and never read the second account's negative row.
    stub_const("#{described_class}::USER_BATCH_SIZE", 2)
    earlier_seller = create(:user)
    create(:balance, user: earlier_seller, date: in_cycle_date,
                     merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                     amount_cents: 100_00, holding_amount_cents: 100_00)
    second_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                               currency: Currency::PHP, country: "PH")
    residue_row(100_00)
    create(:balance, user: seller, merchant_account: second_account, date: in_cycle_date,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include(second_account.charge_processor_merchant_id)
    end
  end

  it "reports a seller's later merchant account when a full scan page is entirely that seller's own groups" do
    # USER_BATCH_SIZE = 1: the seller's first account alone fills a page, so
    # `batch.first.first == batch.last.first` on every page — the boundary case the straddle test
    # above cannot reach, since there is no *other* user in the page to make the ids differ. A
    # cursor keyed on user_id alone would advance past this seller after page 1 and never read the
    # second account's negative row.
    stub_const("#{described_class}::USER_BATCH_SIZE", 1)
    second_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                               currency: Currency::PHP, country: "PH")
    residue_row(100_00)
    create(:balance, user: seller, merchant_account: second_account, date: in_cycle_date,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include(second_account.charge_processor_merchant_id)
    end
  end

  it "does not report a negative row that healthy rows on the same account outweigh, because the payout guard lets that set through" do
    residue_row(-100_00)
    create(:balance, user: seller, merchant_account:, date: in_cycle_date - 1,
                     holding_currency: Currency::PHP, holding_amount_cents: 500_00)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a negative row dated after the payout cutoff, marked, because the instant payout paths read past the cutoff" do
    residue_row(-728_50, date: User::PayoutSchedule.next_scheduled_payout_end_date + 1)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include("[post-cutoff — instant payout paths only until the cycle rolls]")
    end
  end

  it "still reports post-cutoff residue when in-cycle refund netting silences the cycle window" do
    # The cycle window trips negative but is refund netting (matched negative USD), which the
    # payout guard passes — each window is judged whole, so the netted cycle must not swallow
    # post-cutoff residue that leaves the whole ledger in the guard's trip shape (negative
    # destination, non-negative USD), which an instant payout will still fail on.
    create(:balance, user: seller, merchant_account:, date: in_cycle_date,
                     amount_cents: -300_00, holding_currency: Currency::PHP, holding_amount_cents: -300_00)
    residue_row(-728_50, date: User::PayoutSchedule.next_scheduled_payout_end_date + 1)
    create(:balance, user: seller, merchant_account:,
                     date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                     amount_cents: 400_00, holding_currency: Currency::PHP, holding_amount_cents: 400_00)
    make_payable(1_500_00)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include("[post-cutoff")
    end
  end

  it "shows the whole-ledger total beside an in-cycle trip that sits on top of post-cutoff residue" do
    residue_row(-300_00)
    residue_row(-728_50, date: User::PayoutSchedule.next_scheduled_payout_end_date + 1)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("-30000 php cents (-102850 including post-cutoff residue)")
    end
  end

  it "reports in-cycle residue even when a positive row dated after the cutoff would net the account positive" do
    # The weekly payout run sums only up to the cutoff, so the post-cutoff credit does not save it —
    # a whole-ledger-only read would net positive here and miss the payout that is about to fail.
    residue_row(-728_50)
    create(:balance, user: seller, merchant_account:,
                     date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: 900_00)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include(seller.email)
      expect(message).to include("-72850 php cents")
      expect(message).not_to include("[post-cutoff")
    end
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
    residue_row(-300_00, date: in_cycle_date - 2)
    residue_row(-428_50, date: in_cycle_date - 1)
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

  describe "when the candidate scan is truncated" do
    # The bound is the only thing standing between this job and a statement timeout, so the report
    # has to say when it stopped early. A truncated scan that found nothing is NOT evidence that
    # nothing is there, and these are the examples that keep that distinction honest.
    before { stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1) }

    it "still reports when the truncated page found nobody payable, because the bound decided that, not the platform" do
      # Two candidate pairs, neither payable: without truncation this is silence.
      residue_row(-728_50)
      other = create(:user)
      other_account = create(:merchant_account, user: other, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                                currency: Currency::PHP, country: "PH")
      create(:balance, user: other, merchant_account: other_account, date: in_cycle_date,
                       amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to include("the scan was truncated, so this is not evidence that none do")
        expect(message).to include("The scan stopped at 1 negative rows")
      end
    end

    it "marks the count as a floor rather than a total" do
      residue_row(-728_50)
      make_payable
      other = create(:user)
      other_account = create(:merchant_account, user: other, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                                currency: Currency::PHP, country: "PH")
      create(:balance, user: other, merchant_account: other_account, date: in_cycle_date,
                       amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to include("At least 1 payable seller")
      end
    end
  end

  it "caps the lines it prints and says how many it left out, so the alert stays readable" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    residue_row(-728_50)
    make_payable

    other = create(:user)
    other_account = create(:merchant_account, user: other, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                              charge_processor_merchant_id: "acct_negdest_#{SecureRandom.hex(6)}",
                                              currency: Currency::PHP, country: "PH")
    create(:balance, user: other, merchant_account: other_account, date: in_cycle_date,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -900_00)
    create(:balance, user: other, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                     date: in_cycle_date, amount_cents: 200_00, holding_amount_cents: 200_00)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("2 payable sellers")
      expect(message).to include("…and 1 more.")
      # Most negative first, so the capped line is the smaller one.
      expect(message).to include(other.email)
      expect(message).not_to include(seller.email)
    end
  end
end
