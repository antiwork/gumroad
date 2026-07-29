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

  # The SQL narrows to "platform-owned OR not Stripe" before Ruby confirms
  # holder_of_funds, purely to avoid loading every seller's foreign-currency Stripe
  # balance. This example is what proves the narrowing did not throw away the rows the
  # widened scope was added to catch.
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

  # holder_of_funds resolves through the charge processor. A monitor that dies on one row
  # stops watching every other row, so a row it cannot answer for is reported in its own
  # alert -- with its own wording, so an infrastructure failure is never read as a confirmed
  # payout-breaking balance.
  it "reports a row whose holder_of_funds cannot be resolved separately, without dying on it" do
    balance = create_balance_at(after_baseline, holding_currency: Currency::EUR)
    allow_any_instance_of(MerchantAccount).to receive(:holder_of_funds).and_raise(StandardError, "unknown processor")

    expect { described_class.new.perform }.not_to raise_error

    expect(ErrorNotifier).to have_received(:notify).with(
      described_class::UNRESOLVED_MESSAGE,
      hash_including(
        unresolved_count: 1,
        reasons: ["StandardError: unknown processor"],
        unresolved_sample: [hash_including(balance_id: balance.id, reason: "StandardError: unknown processor")]
      )
    )
    # The currency-violation alert would state as fact that a Gumroad-held balance is
    # mislabelled, which is the question that could not be answered for this row.
    expect(ErrorNotifier).not_to have_received(:notify).with(described_class::OFFENDING_MESSAGE, any_args)
  end

  # MerchantAccount#holder_of_funds falls back to GUMROAD for any charge processor it does
  # not recognise, including a missing one -- so these balances break payouts. The SQL has
  # to be phrased so a NULL processor id is KEPT: any comparison against NULL yields NULL,
  # which would silently drop the row.
  it "alerts on a mislabelled balance whose merchant account has no charge processor id" do
    account = create(:merchant_account_paypal, user: create(:user))
    account.update_column(:charge_processor_id, nil)
    balance = travel_to(after_baseline) do
      create(:balance, merchant_account: account, holding_currency: Currency::EUR)
    end

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
  end

  # merchant_accounts carries the same case-insensitive PAD SPACE collation as balances, so a
  # collated comparison calls these "stripe" and would exclude them -- while holder_of_funds,
  # comparing in Ruby against the recognised processor ids, does not recognise them and falls
  # back to GUMROAD. They break payouts and the query has to keep them.
  ["Stripe", "stripe "].each do |raw_processor_id|
    it "alerts on a balance whose merchant account processor id reads #{raw_processor_id.inspect}" do
      account = create(:merchant_account_paypal, user: create(:user))
      account.update_column(:charge_processor_id, raw_processor_id)
      balance = travel_to(after_baseline) do
        create(:balance, merchant_account: account, holding_currency: Currency::EUR)
      end

      described_class.new.perform

      expect(ErrorNotifier).to have_received(:notify).with(
        anything, hash_including(sample: [hash_including(balance_id: balance.id)])
      )
    end
  end

  # Production carries merchant accounts on processor ids that ChargeProcessor no longer
  # recognises (app_store, google_play). holder_of_funds treats those as Gumroad-held on the
  # documented assumption that we hold the funds for removed processors, so a mislabelled
  # balance on one blocks payouts and the query must keep it.
  it "alerts on a balance whose merchant account uses a processor Gumroad no longer recognises" do
    account = create(:merchant_account_paypal, user: create(:user))
    account.update_column(:charge_processor_id, "app_store")
    balance = travel_to(after_baseline) do
      create(:balance, merchant_account: account, holding_currency: Currency::EUR)
    end

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
  end

  # merchant_account_id is nullable, so a row can exist with nothing to resolve. Such a row
  # cannot be judged either way and must not be silently dropped.
  it "reports a row with no merchant account rather than skipping it silently" do
    balance = create_balance_at(after_baseline, holding_currency: Currency::EUR)
    balance.update_column(:merchant_account_id, nil)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      described_class::UNRESOLVED_MESSAGE,
      hash_including(unresolved_sample: [hash_including(balance_id: balance.id, reason: "no merchant account")])
    )
  end

  # The baseline is compared against updated_at, not created_at. A bad holding_currency does not
  # only arrive at row creation: a repair or backfill can rewrite the column on a row that
  # already existed (the model's immutability check covers only the amount columns), and that is
  # the same payout-breaking incident on a row whose created_at is long past. Keying off
  # created_at would never see it. updated_at is written explicitly here because update_columns
  # bypasses the automatic timestamp, which a real save would have bumped.
  it "alerts on an old balance that was mislabelled after the baseline" do
    balance = create_balance_at(before_baseline, holding_currency: Currency::USD)
    balance.update_columns(holding_currency: Currency::EUR, updated_at: after_baseline)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: balance.id)])
    )
  end

  # An old row that was touched since the baseline but carries a correct currency must not
  # become noise -- the widened timestamp only matters together with the currency test.
  it "still ignores an old balance that was touched after the baseline but is labelled in USD" do
    balance = create_balance_at(before_baseline, holding_currency: Currency::USD)
    balance.update_columns(amount_cents: 500, updated_at: after_baseline)

    described_class.new.perform

    expect(ErrorNotifier).not_to have_received(:notify)
  end

  # The sample is capped so the alert stays readable, but a capped sample must not be
  # mistaken for a small problem: the counts describe everything that was read.
  it "caps the sample without understating how many balances are affected" do
    balances = Array.new(described_class::SAMPLE_LIMIT + 3) do
      create_balance_at(after_baseline, holding_currency: Currency::EUR)
    end

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything,
      hash_including(balance_count: balances.size, hit_row_limit: false)
    )
    expect(ErrorNotifier).to have_received(:notify) do |_message, context|
      expect(context[:sample].size).to eq(described_class::SAMPLE_LIMIT)
    end
  end

  it "reports the seller count and the currencies so the cause is legible from the alert" do
    create_balance_at(after_baseline, holding_currency: Currency::EUR)
    create_balance_at(after_baseline, holding_currency: "usdd")

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(balance_count: 2, currencies: match_array([Currency::EUR, "usdd"]))
    )
  end

  # Once the ceiling is hit the counts describe only the rows that were read, so the alert has
  # to say so -- otherwise a mislabelling at scale reads as exactly MAX_ROWS_LOADED balances --
  # and it reports how many rows the query matched, because "500" reads the same whether the
  # real number is 501 or 50,000.
  it "says the row ceiling was hit and reports the candidate total, so the counts are not mistaken for the whole picture" do
    stub_const("#{described_class}::MAX_ROWS_LOADED", 2)
    3.times { create_balance_at(after_baseline, holding_currency: Currency::EUR) }

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(balance_count: 2, hit_row_limit: true, candidate_row_count: 3)
    )
  end

  # The truncation total spans both buckets, so it must not be reported under a name that reads
  # as either one's total: with a mixed truncated run, a "matching balances" figure in the
  # currency-violation alert would count the unresolvable rows as confirmed violations.
  it "keeps the truncation total distinct from each bucket's own count when a truncated run finds both" do
    stub_const("#{described_class}::MAX_ROWS_LOADED", 2)
    offending = create_balance_at(after_baseline, holding_currency: Currency::EUR)
    unresolvable = create_balance_at(after_baseline, holding_currency: Currency::EUR)
    unresolvable.update_column(:merchant_account_id, nil)
    create_balance_at(after_baseline, holding_currency: Currency::EUR)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      described_class::OFFENDING_MESSAGE,
      hash_including(
        balance_count: 1,
        hit_row_limit: true,
        candidate_row_count: 3,
        sample: [hash_including(balance_id: offending.id)]
      )
    )
    expect(ErrorNotifier).to have_received(:notify).with(
      described_class::UNRESOLVED_MESSAGE,
      hash_including(unresolved_count: 1, hit_row_limit: true, candidate_row_count: 3)
    )
    expect(ErrorNotifier).to have_received(:notify).twice
  end

  # The SQL excludes a seller's own Stripe Connect account rather than leaning on the Ruby
  # holder_of_funds check alone, and that exclusion is load-bearing rather than a mere
  # optimisation: production carries hundreds of legitimately non-USD seller-Connect balances,
  # and with rows read oldest-first under a fixed ceiling they would crowd a genuinely
  # mislabelled Gumroad-held balance out of every run -- permanent silence. Delete the
  # exclusion from the query and this example goes red.
  it "does not let seller Stripe Connect balances crowd a Gumroad-held one out of the row budget" do
    stub_const("#{described_class}::MAX_ROWS_LOADED", 1)
    seller_account = create(:merchant_account_stripe_connect, currency: Currency::EUR)
    travel_to(after_baseline) do
      create(:balance, merchant_account: seller_account, currency: Currency::EUR, holding_currency: Currency::EUR)
    end
    gumroad_held = create_balance_at(after_baseline, holding_currency: Currency::EUR)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      anything, hash_including(sample: [hash_including(balance_id: gumroad_held.id)])
    )
  end

  # The two buckets call for different responses -- fix the balance versus fix the monitor or
  # the merchant account -- so when a run finds both they are reported as two alerts and the
  # counts in each describe only its own bucket.
  it "reports a mislabelled balance and an unresolvable row as separate alerts" do
    offending = create_balance_at(after_baseline, holding_currency: Currency::EUR)
    unresolvable = create_balance_at(after_baseline, holding_currency: Currency::EUR)
    unresolvable.update_column(:merchant_account_id, nil)

    described_class.new.perform

    expect(ErrorNotifier).to have_received(:notify).with(
      described_class::OFFENDING_MESSAGE,
      hash_including(balance_count: 1, sample: [hash_including(balance_id: offending.id)])
    )
    expect(ErrorNotifier).to have_received(:notify).with(
      described_class::UNRESOLVED_MESSAGE,
      hash_including(unresolved_count: 1, unresolved_sample: [hash_including(balance_id: unresolvable.id)])
    )
  end

  # The job only ever runs from the schedule, so a missing or renamed entry means the monitor
  # silently never runs -- the exact failure mode it was written to prevent.
  it "is scheduled daily ahead of the payouts run" do
    entry = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).values.find { _1["class"] == described_class.name }

    expect(entry).to be_present
    expect(entry["cron"]).to eq("30 7 * * *")
  end
end
