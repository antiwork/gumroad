# frozen_string_literal: true

describe CollectUnclaimedBalancesOfInactiveStripeAccountsJob do
  describe "#perform", :vcr do
    before do
      stub_const("CollectUnclaimedBalancesOfInactiveStripeAccountsJob::STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION", 3.weeks)
    end

    it "collects the balance amount from inactive Stripe US merchant accounts" do
      us_stripe_account_1 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account_1.user, merchant_account: us_stripe_account_1, amount_cents: 100_00)
      us_stripe_account_2 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SOZihINUYgu4sRU", created_at: 1.month.ago)
      create(:balance, user: us_stripe_account_2.user, merchant_account: us_stripe_account_2, amount_cents: 200_00)

      expect(Stripe::Account).to receive(:retrieve).twice.and_call_original
      expect(Stripe::Payout).to receive(:list).twice.and_return(double(data: []))
      expect(Stripe::Charge).to receive(:list).twice.and_return(double(data: []))
      expect(Stripe::Balance).to receive(:retrieve).twice.and_call_original
      expect(Stripe::Transfer).to receive(:create).twice.and_call_original

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform

      expect(us_stripe_account_1.reload.unclaimed_balance_collection_transfer_id).to match(/^tr_/)
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: us_stripe_account_1.id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 100_00
      expect(us_stripe_account_2.reload.unclaimed_balance_collection_transfer_id).to match(/^tr_/)
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: us_stripe_account_2.id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 200_00
    end

    it "does not attempt to collect balance from non-US Stripe merchant accounts" do
      uk_stripe_account = create(:merchant_account, country: "UK", currency: "gbp", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: uk_stripe_account.user, merchant_account: uk_stripe_account, amount_cents: 100_00)
      canada_stripe_account = create(:merchant_account, country: "CA", currency: "cad", charge_processor_merchant_id: "acct_1SOZihINUYgu4sRU", created_at: 1.month.ago)
      create(:balance, user: canada_stripe_account.user, merchant_account: canada_stripe_account, amount_cents: 200_00)

      expect(Stripe::Account).not_to receive(:retrieve)
      expect(Stripe::Payout).not_to receive(:list)
      expect(Stripe::Charge).not_to receive(:list)
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform

      expect(uk_stripe_account.user.unpaid_balances.where(merchant_account_id: uk_stripe_account.id).sum(:holding_amount_cents)).to eq 100_00
      expect(canada_stripe_account.user.unpaid_balances.where(merchant_account_id: canada_stripe_account.id).sum(:holding_amount_cents)).to eq 200_00
    end

    it "does not attempt to collect balance from any PayPal merchant accounts" do
      create(:merchant_account_paypal, country: "US", currency: "usd", charge_processor_merchant_id: "B66YJBBNCRW6L", created_at: 2.months.ago)
      create(:merchant_account_paypal, country: "US", currency: "usd", charge_processor_merchant_id: "F8Z2DAMTCQ7R8", created_at: 1.month.ago)

      expect(Stripe::Account).not_to receive(:retrieve)
      expect(Stripe::Payout).not_to receive(:list)
      expect(Stripe::Charge).not_to receive(:list)
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
    end

    it "does not attempt to collect balance from merchant accounts that are considered active based on creation date" do
      create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SqSQnISXZefT5QU", created_at: 2.weeks.ago)
      create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SuxabRHAgixSinm", created_at: 1.week.ago)
      create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SueNiRCSRy9PT87", created_at: 1.day.ago)
      create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1Sud0PRR91j3a5Wr", created_at: 1.hour.ago)

      expect(Stripe::Account).not_to receive(:retrieve)
      expect(Stripe::Payout).not_to receive(:list)
      expect(Stripe::Charge).not_to receive(:list)
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
    end

    it "does not attempt to collect balance from merchant accounts that are considered active based on user's last payout" do
      us_stripe_account_1 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account_1.user, merchant_account: us_stripe_account_1, amount_cents: 100_00)
      us_stripe_account_2 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SOZihINUYgu4sRU", created_at: 1.month.ago)
      create(:balance, user: us_stripe_account_2.user, merchant_account: us_stripe_account_2, amount_cents: 200_00)

      create(:payment_completed, user: us_stripe_account_1.user, created_at: 1.week.ago)
      expect(Stripe::Account).to receive(:retrieve).once.and_call_original
      expect(Stripe::Payout).to receive(:list).once.and_return(double(data: []))
      expect(Stripe::Charge).to receive(:list).once.and_return(double(data: []))
      expect(Stripe::Balance).to receive(:retrieve).once.and_call_original
      expect(Stripe::Transfer).to receive(:create).once.and_call_original

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform

      expect(us_stripe_account_1.reload.unclaimed_balance_collection_transfer_id).to be nil
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: us_stripe_account_1.id).sum(:holding_amount_cents)).to eq 100_00
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_2.reload.unclaimed_balance_collection_transfer_id).to match(/^tr_/)
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: us_stripe_account_2.id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 200_00
    end

    it "does not attempt to collect balance from merchant accounts that are considered active based on users' last sale" do
      us_stripe_account_1 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account_1.user, merchant_account: us_stripe_account_1, amount_cents: 100_00)
      us_stripe_account_2 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SOZihINUYgu4sRU", created_at: 1.month.ago)
      create(:balance, user: us_stripe_account_2.user, merchant_account: us_stripe_account_2, amount_cents: 200_00)

      create(:purchase, link: create(:product, user: us_stripe_account_2.user), created_at: 1.week.ago)
      expect(Stripe::Account).to receive(:retrieve).once.and_call_original
      expect(Stripe::Payout).to receive(:list).once.and_return(double(data: []))
      expect(Stripe::Charge).to receive(:list).once.and_return(double(data: []))
      expect(Stripe::Balance).to receive(:retrieve).once.and_call_original
      expect(Stripe::Transfer).to receive(:create).once.and_call_original

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform

      expect(us_stripe_account_1.reload.unclaimed_balance_collection_transfer_id).to match(/^tr_/)
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: us_stripe_account_1.id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 100_00
      expect(us_stripe_account_2.reload.unclaimed_balance_collection_transfer_id).to be nil
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: us_stripe_account_2.id).sum(:holding_amount_cents)).to eq 200_00
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 0
    end

    it "does not attempt to collect balance from merchant accounts that have already been processed" do
      us_stripe_account_1 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account_1.user, merchant_account: us_stripe_account_1, amount_cents: 100_00)
      us_stripe_account_2 = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SOZihINUYgu4sRU", created_at: 1.month.ago)
      create(:balance, user: us_stripe_account_2.user, merchant_account: us_stripe_account_2, amount_cents: 200_00)

      us_stripe_account_1.update!(unclaimed_balance_collection_transfer_id: "tr_12345")

      expect(Stripe::Account).to receive(:retrieve).once.and_call_original
      expect(Stripe::Payout).to receive(:list).once.and_return(double(data: []))
      expect(Stripe::Charge).to receive(:list).once.and_return(double(data: []))
      expect(Stripe::Balance).to receive(:retrieve).once.and_call_original
      expect(Stripe::Transfer).to receive(:create).once.and_call_original

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform

      expect(us_stripe_account_1.reload.unclaimed_balance_collection_transfer_id).to eq "tr_12345"
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: us_stripe_account_1.id).sum(:holding_amount_cents)).to eq 100_00
      expect(us_stripe_account_1.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_2.reload.unclaimed_balance_collection_transfer_id).to match(/^tr_/)
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: us_stripe_account_2.id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account_2.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 200_00
    end

    it "does not attempt to collect balance if the Stripe account is considered active based on creation date" do
      # Freeze time to keep VCR cassette timestamps (recorded Feb 3, 2026) within the stubbed 3-week
      # STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION window. Without this, the test breaks as real time drifts
      # past the cassette dates.
      travel_to(Date.new(2026, 2, 11)) do
        us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SwhnzEqM4HpFFlW", created_at: 2.months.ago)
        create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

        expect(Stripe::Account).to receive(:retrieve).and_call_original
        expect(Stripe::Payout).not_to receive(:list)
        expect(Stripe::Charge).not_to receive(:list)
        expect(Stripe::Balance).not_to receive(:retrieve)
        expect(Stripe::Transfer).not_to receive(:create)

        CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
      end
    end

    it "does not attempt to collect balance if the Stripe account is considered active based on last payout date" do
      # Freeze time to keep VCR cassette timestamps (recorded Feb 3, 2026) within the stubbed 3-week
      # STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION window. Without this, the test breaks as real time drifts
      # past the cassette dates.
      travel_to(Date.new(2026, 2, 11)) do
        us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SksUmIK1urmCqcP", created_at: 2.months.ago)
        create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

        expect(Stripe::Account).to receive(:retrieve).and_call_original
        expect(Stripe::Payout).to receive(:list).and_call_original
        expect(Stripe::Charge).not_to receive(:list)
        expect(Stripe::Balance).not_to receive(:retrieve)
        expect(Stripe::Transfer).not_to receive(:create)

        CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
      end
    end

    it "does not attempt to collect balance if the Stripe account is considered active based on last charge date" do
      # Freeze time to keep VCR cassette timestamps (recorded Feb 3, 2026) within the stubbed 3-week
      # STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION window. Without this, the test breaks as real time drifts
      # past the cassette dates.
      travel_to(Date.new(2026, 2, 11)) do
        us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SkrZURRjYPUisng", created_at: 2.months.ago)
        create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

        expect(Stripe::Account).to receive(:retrieve).and_call_original
        expect(Stripe::Payout).to receive(:list).and_call_original
        expect(Stripe::Charge).to receive(:list).and_call_original
        expect(Stripe::Balance).not_to receive(:retrieve)
        expect(Stripe::Transfer).not_to receive(:create)

        CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
      end
    end

    it "does not attempt to collect balance if the Stripe account is a standard Stripe account" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      expect(Stripe::Account).to receive(:retrieve).and_call_original
      expect(Stripe::Payout).not_to receive(:list).and_call_original
      expect(Stripe::Charge).not_to receive(:list).and_call_original
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
    end

    # Two executions can overlap: the job has no uniqueness lock, so a cron double-fire or a
    # manual enqueue alongside the scheduled run can both read a positive balance before either
    # of them transfers. Stripe collapses the second transfer into the first only if both carry
    # the same key, so what matters is that the key is DETERMINISTIC — derived from the account
    # and amount rather than random per request, which is what the Stripe client would otherwise
    # attach on its own.
    it "sends a deterministic idempotency key derived from the account and amount, so two overlapping runs can't both transfer" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      # Stubbed rather than replayed from a cassette: this example is about the exact request the
      # job sends, so the balance is pinned rather than taken from a recording.
      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 100_00 }], "pending" => [{ "amount" => 0 }] }
      )

      idempotency_keys = []
      allow(Stripe::Transfer).to receive(:create) do |_params, opts|
        idempotency_keys << opts[:idempotency_key]
        double(id: "tr_collected")
      end

      described_class.new.perform

      # Asserted as the exact string: a nil key would satisfy a "both runs agree" check.
      expect(idempotency_keys).to eq(["collect_unclaimed_balance_acct_1SO1bwI533JwXS4r_10000"])
      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to eq("tr_collected")
    end

    # The transfer id is what stops the account from being selected again, so saving it while
    # leaving Balance rows behind would strand them on the dead merchant account forever — no
    # later run would ever look at the account again. Two balances, failing on the second, so
    # the assertion catches a PARTIAL move and not just an unstamped id.
    it "does not record the transfer id or move any balances if moving one of them fails" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 60_00, date: Date.new(2023, 1, 1))
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 40_00, date: Date.new(2023, 1, 2))

      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 100_00 }], "pending" => [{ "amount" => 0 }] }
      )
      allow(Stripe::Transfer).to receive(:create).and_return(double(id: "tr_collected"))

      # The worker dies part-way through the loop: the first balance moves, the second doesn't.
      moved = 0
      allow_any_instance_of(Balance).to receive(:update!).and_wrap_original do |original, *args|
        moved += 1
        raise Sidekiq::Shutdown if moved > 1
        original.call(*args)
      end

      expect { described_class.new.perform }.to raise_error(Sidekiq::Shutdown)

      # Rolled back together, INCLUDING the balance that had already moved, so the account stays
      # selectable and the next run can finish the job rather than leaving it half-collected.
      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to be_nil
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: us_stripe_account.id).sum(:holding_amount_cents)).to eq 100_00
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 0
    end

    # Continues the example above. After the rollback the money has already left the connected
    # account, so the next run sees a zero balance — it has to recognise the transfer it made last
    # time and finish the bookkeeping, otherwise the balances are stranded for good.
    it "finishes the bookkeeping on a later run when an earlier run transferred but did not record it" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      # The earlier run already swept the account, so there is nothing left on Stripe's side.
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 0 }], "pending" => [{ "amount" => 0 }] }
      )
      allow(Stripe::Transfer).to receive(:list).and_return(
        double(data: [double(id: "tr_from_earlier_run",
                             description: described_class::TRANSFER_DESCRIPTION,
                             destination: STRIPE_PLATFORM_ACCOUNT_ID,
                             amount_reversed: 0)])
      )
      expect(Stripe::Transfer).not_to receive(:create)

      described_class.new.perform

      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to eq "tr_from_earlier_run"
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: us_stripe_account.id).sum(:holding_amount_cents)).to eq 0
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id).sum(:holding_amount_cents)).to eq 100_00
    end

    it "leaves an empty account alone when the only transfers on it were not made by this job" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 0 }], "pending" => [{ "amount" => 0 }] }
      )
      # Someone else's transfer out of the same account: right shape, not ours to reconcile.
      allow(Stripe::Transfer).to receive(:list).and_return(
        double(data: [double(id: "tr_unrelated", description: "Something else", destination: "acct_other", amount_reversed: 0)])
      )
      expect(Stripe::Transfer).not_to receive(:create)

      described_class.new.perform

      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to be_nil
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: us_stripe_account.id).sum(:holding_amount_cents)).to eq 100_00
    end

    # Gumroad makes other connected-account-to-platform transfers that this job did not make —
    # backtax collection and fee-retention debits both land on the platform account and send no
    # description. Recovering one of those would record a collection that never happened and move
    # the seller's balances for money this job never swept, so the description is what tells them
    # apart. Pinned here because dropping either half of the match would otherwise pass the suite.
    it "leaves an empty account alone when a transfer to the platform account was not made by this job" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 0 }], "pending" => [{ "amount" => 0 }] }
      )
      # The backtax/fee-retention shape: destination matches, no description.
      allow(Stripe::Transfer).to receive(:list).and_return(
        double(data: [double(id: "tr_backtax", description: nil, destination: STRIPE_PLATFORM_ACCOUNT_ID, amount_reversed: 0)])
      )

      described_class.new.perform

      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to be_nil
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: us_stripe_account.id).sum(:holding_amount_cents)).to eq 100_00
    end

    # The mirror of the above: our description, but the money went somewhere other than Gumroad's
    # platform account, so it isn't a collection either.
    it "leaves an empty account alone when a transfer with this job's description went elsewhere" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 0 }], "pending" => [{ "amount" => 0 }] }
      )
      allow(Stripe::Transfer).to receive(:list).and_return(
        double(data: [double(id: "tr_elsewhere", description: described_class::TRANSFER_DESCRIPTION, destination: "acct_somewhere_else", amount_reversed: 0)])
      )

      described_class.new.perform

      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to be_nil
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: us_stripe_account.id).sum(:holding_amount_cents)).to eq 100_00
    end

    # If ops already reversed the orphaned transfer by hand — a plausible cleanup for exactly this
    # situation — the money went back to the seller, so there is no collection to record.
    it "leaves an empty account alone when the transfer this job made was reversed" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SO1bwI533JwXS4r", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      allow(Stripe::Payout).to receive(:list).and_return(double(data: []))
      allow(Stripe::Charge).to receive(:list).and_return(double(data: []))
      allow(Stripe::Account).to receive(:retrieve).and_return(double(type: "custom", created: 5.years.ago.to_i))
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        { "available" => [{ "amount" => 0 }], "pending" => [{ "amount" => 0 }] }
      )
      allow(Stripe::Transfer).to receive(:list).and_return(
        double(data: [double(id: "tr_reversed", description: described_class::TRANSFER_DESCRIPTION, destination: STRIPE_PLATFORM_ACCOUNT_ID, amount_reversed: 100_00)])
      )

      described_class.new.perform

      expect(us_stripe_account.reload.unclaimed_balance_collection_transfer_id).to be_nil
      expect(us_stripe_account.user.unpaid_balances.where(merchant_account_id: us_stripe_account.id).sum(:holding_amount_cents)).to eq 100_00
    end
  end
end
