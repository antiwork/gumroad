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

  # The model validates holding_currency presence and would reject some of the
  # malformed values under test on the way in. Production got these rows anyway (the
  # 2023 typos this monitor was written for), so plant them the same way: past the
  # validations, straight into the column.
  def create_balance_with_raw_currency(time, raw_currency)
    create_balance_at(time).tap { _1.update_column(:holding_currency, raw_currency) }
  end

  it "does not alert when every Gumroad-held balance is labelled in USD" do
    create_balance_at(after_baseline, holding_currency: Currency::USD)

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  it "alerts on a Gumroad-held balance labelled in a buyer's currency" do
    balance = create_balance_at(after_baseline, holding_currency: Currency::EUR)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      a_string_including("holding_currency other than USD"),
      hash_including(
        balance_count: 1,
        currencies: [Currency::EUR],
        sample: [hash_including(balance_id: balance.id, seller_id: balance.user_id)]
      )
    )
  end

  # The two rows found in production carried "usdd" and "usd\n" — 2023 data entry with
  # nothing to do with buyer-currency presentment. Both payout processors compare the
  # column to the literal "usd" in Ruby, so they fail payouts identically, and a monitor
  # that only looked for known currency codes would have missed them entirely.
  it "alerts on a malformed currency string that is not a currency code at all" do
    balance = create_balance_at(after_baseline, holding_currency: "usdd")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
  end

  it "alerts on a trailing-newline variant of USD, which the processors' comparison rejects" do
    balance = create_balance_with_raw_currency(after_baseline, "usd\n")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
  end

  # The balances table is utf8mb4_unicode_ci: case-insensitive and PAD SPACE. A plain SQL
  # `holding_currency != "usd"` therefore considers all three of these EQUAL to "usd" and
  # skips them, while the processors compare in Ruby and fail the payout. These three
  # examples are what force the query to compare binary.
  ["USD", "Usd", "usd "].each do |raw_currency|
    it "alerts on #{raw_currency.inspect}, which the table's collation considers equal to usd" do
      balance = create_balance_with_raw_currency(after_baseline, raw_currency)

      described_class.new.perform

      expect(ErrorNotifier).to have_received(:notify).with(
        anything, hash_including(sample: [hash_including(balance_id: balance.id)])
      )
    end
  end

  # `NULL != "usd"` is NULL in SQL, so a NULL row is dropped from a naive query — but
  # `nil == "usd"` is false in Ruby, so PayPal short-pays and Stripe fails the payment.
  it "alerts on a NULL holding_currency, which SQL inequality alone would filter out" do
    balance = create_balance_with_raw_currency(after_baseline, nil)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
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

  # A seller's own Stripe Connect account legitimately holds foreign currency: there
  # holding_currency describes that account's real balance, StripePayoutProcessor compares
  # it to the account's own currency rather than to USD, and holder_of_funds is CREATOR.
  it "ignores a non-USD balance on a seller's own Stripe Connect account" do
    seller_account = create(:merchant_account_stripe_connect, currency: Currency::EUR)
    travel_to(after_baseline) do
      create(:balance, merchant_account: seller_account, currency: Currency::EUR, holding_currency: Currency::EUR)
    end

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  # PaypalChargeProcessor#holder_of_funds returns GUMROAD for EVERY merchant account,
  # including a seller's own, so these balances break payouts exactly like the platform
  # account's do. Scoping the query on `merchant_accounts.user_id IS NULL` would have
  # missed them, which is why the Gumroad-held test is holder_of_funds instead.
  it "alerts on a mislabelled balance held by Gumroad through a seller's PayPal merchant account" do
    paypal_account = create(:merchant_account_paypal, user: create(:user))
    balance = travel_to(after_baseline) do
      create(:balance, merchant_account: paypal_account, holding_currency: Currency::EUR)
    end

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
  end

  it "reports the seller count and the currencies so the cause is legible from the alert" do
    create_balance_at(after_baseline, holding_currency: Currency::EUR)
    create_balance_at(after_baseline, holding_currency: "usdd")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(balance_count: 2, currencies: match_array([Currency::EUR, "usdd"]))
    )
  end
end
