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
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SwhnzEqM4HpFFlW", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      expect(Stripe::Account).to receive(:retrieve).and_call_original
      expect(Stripe::Payout).not_to receive(:list)
      expect(Stripe::Charge).not_to receive(:list)
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
    end

    it "does not attempt to collect balance if the Stripe account is considered active based on last payout date" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SksUmIK1urmCqcP", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      expect(Stripe::Account).to receive(:retrieve).and_call_original
      expect(Stripe::Payout).to receive(:list).and_call_original
      expect(Stripe::Charge).not_to receive(:list)
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
    end

    it "does not attempt to collect balance if the Stripe account is considered active based on last charge date" do
      us_stripe_account = create(:merchant_account, country: "US", currency: "usd", charge_processor_merchant_id: "acct_1SkrZURRjYPUisng", created_at: 2.months.ago)
      create(:balance, user: us_stripe_account.user, merchant_account: us_stripe_account, amount_cents: 100_00)

      expect(Stripe::Account).to receive(:retrieve).and_call_original
      expect(Stripe::Payout).to receive(:list).and_call_original
      expect(Stripe::Charge).to receive(:list).and_call_original
      expect(Stripe::Balance).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create)

      CollectUnclaimedBalancesOfInactiveStripeAccountsJob.new.perform
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
  end
end
