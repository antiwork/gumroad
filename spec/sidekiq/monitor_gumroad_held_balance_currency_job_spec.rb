# frozen_string_literal: true

describe MonitorGumroadHeldBalanceCurrencyJob do
  let(:gumroad_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }
  let(:after_baseline) { described_class::BASELINE_CUTOFF + 1.day }
  let(:before_baseline) { described_class::BASELINE_CUTOFF - 1.day }

  before do
    allow(ErrorNotifier).to receive(:notify)
  end

  # Balances are created with created_at set by Rails, so travel to place a row on
  # either side of the baseline rather than writing created_at directly.
  def create_balance_at(time, **attrs)
    travel_to(time) { create(:balance, merchant_account: gumroad_account, **attrs) }
  end

  it "does not alert when every Gumroad-held balance is labelled in USD" do
    create_balance_at(after_baseline, holding_currency: Currency::USD)

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  it "alerts on a Gumroad-held balance labelled in a buyer's currency" do
    balance = create_balance_at(after_baseline, holding_currency: Currency::EUR)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(a_string_including("balance=#{balance.id}"))
    expect(ErrorNotifier).to have_received(:notify).with(a_string_including("\"eur\""))
  end

  # The two rows found in production carried "usdd" and "usd\n" — 2023 data entry with
  # nothing to do with buyer-currency presentment. Both payout processors compare the
  # column to the literal "usd", so they fail payouts identically, and a monitor that
  # only looked for known currency codes would have missed them entirely.
  it "alerts on a malformed currency string that is not a currency code at all" do
    balance = create_balance_at(after_baseline, holding_currency: "usdd")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(a_string_including("balance=#{balance.id}"))
  end

  it "alerts on a trailing-whitespace variant of USD, which the exact comparison rejects" do
    balance = create_balance_at(after_baseline, holding_currency: "usd\n")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(a_string_including("balance=#{balance.id}"))
  end

  it "ignores the known historical cohort, so the alert means something new appeared" do
    create_balance_at(before_baseline, holding_currency: Currency::EUR)

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  # A paid balance cannot block a future payout, so reporting it would be noise.
  it "ignores a mislabelled balance that has already been paid out" do
    create_balance_at(after_baseline, holding_currency: Currency::EUR, state: "paid")

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  # A seller's own connected account legitimately holds foreign currency: there
  # holding_currency describes that account's real balance, and StripePayoutProcessor
  # compares it to the account's own currency rather than to USD.
  it "ignores a non-USD balance on a seller's own connected account" do
    seller_account = create(:merchant_account, user: create(:user), currency: Currency::EUR,
                                               charge_processor_merchant_id: "acct_#{SecureRandom.hex(6)}")
    travel_to(after_baseline) do
      create(:balance, merchant_account: seller_account, currency: Currency::EUR, holding_currency: Currency::EUR)
    end

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  it "reports the seller count and the currencies so the cause is legible from the alert" do
    create_balance_at(after_baseline, holding_currency: Currency::EUR)
    create_balance_at(after_baseline, holding_currency: "usdd")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(a_string_including("2 row(s)"))
  end
end
