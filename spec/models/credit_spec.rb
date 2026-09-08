# frozen_string_literal: true

require "spec_helper"

describe Credit do
  describe "create_for_credit!" do
    let(:user) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user:) }

    it "assigns to the Gumroad Stripe merchant account" do
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      expect(credit.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
    end

    it "updates the unpaid_balance_cents for users after creation" do
      balance_before_credit = user.unpaid_balance_cents
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      balance_after_credit = user.reload.unpaid_balance_cents
      expect(balance_after_credit).to eq(balance_before_credit + credit.amount_cents)
    end

    it "creates a balance record after credit" do
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      expect(credit.balance).to eq(Balance.last)
    end

    it "creates a comment after credit" do
      comment_count_before_credit = user.comments.count
      Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      expect(user.reload.comments.count).to eq(comment_count_before_credit + 1)
      expect(user.reload.comments.last.content).to include("issued $10 credit")
    end

    it "applies the credit to the oldest unpaid balance" do
      old_balance = create(:balance, user:, date: 10.days.ago)
      balance_before_credit = user.unpaid_balance_cents
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      balance_after_credit = user.reload.unpaid_balance_cents
      expect(balance_after_credit).to eq(balance_before_credit + credit.amount_cents)
      expect(credit.balance).to eq(old_balance)
    end

    it "applies the credit to an unpaid balance for the Gumroad Stripe merchant account" do
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      expect(credit.balance.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
    end

    it "stores the reason on the credit" do
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first, reason: "Goodwill for reported checkout bug")
      expect(credit.reason).to eq("Goodwill for reported checkout bug")
    end

    it "includes the reason in the comment" do
      Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first, reason: "Goodwill for reported checkout bug")
      expect(user.reload.comments.last.content).to eq("issued $10 credit — Goodwill for reported checkout bug.")
    end

    it "omits the dash when no reason is given" do
      Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first)
      expect(user.reload.comments.last.content).to eq("issued $10 credit.")
    end
  end

  describe "#notify_user" do
    let(:user) { create(:user) }

    it "sends the credit notification including the reason" do
      credit = Credit.create_for_credit!(user:, amount_cents: 1000, crediting_user: User.first, reason: "Goodwill for reported checkout bug")
      mailer = double(deliver_later: true)
      expect(ContactingCreatorMailer).to receive(:credit_notification).with(user.id, 1000, "Goodwill for reported checkout bug").and_return(mailer)
      credit.notify_user
    end
  end

  describe "create_for_dispute_won!" do
    let(:user) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user:) }
    let(:purchase) { create(:purchase) }
    let(:dispute) { create(:dispute, purchase:) }
    let(:balance_transaction_issued_amount) do
      BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: 100_00,
        net_cents: 88_90
      )
    end
    let(:balance_transaction_holding_amount) do
      BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: 200_00,
        net_cents: 177_80
      )
    end

    it "assigns the purchase of the dispute as the chargebacked purchase" do
      credit = Credit.create_for_dispute_won!(user:, merchant_account:, dispute:,
                                              chargedback_purchase: purchase,
                                              balance_transaction_issued_amount:,
                                              balance_transaction_holding_amount:)
      expect(credit.chargebacked_purchase).to eq(purchase)
    end

    it "updates the unpaid_balance_cents for users after creation" do
      balance_before_credit = user.unpaid_balance_cents
      credit = Credit.create_for_dispute_won!(user:, merchant_account:, dispute:,
                                              chargedback_purchase: purchase,
                                              balance_transaction_issued_amount:,
                                              balance_transaction_holding_amount:)
      balance_after_credit = user.reload.unpaid_balance_cents
      expect(balance_after_credit).to eq(balance_before_credit + credit.amount_cents)
    end

    it "creates a balance record after credit" do
      credit = Credit.create_for_dispute_won!(user:, merchant_account:, dispute:,
                                              chargedback_purchase: purchase,
                                              balance_transaction_issued_amount:,
                                              balance_transaction_holding_amount:)
      expect(credit.balance).to eq(Balance.last)
    end

    it "creates a comment after credit" do
      comment_count_before_credit = user.comments.count
      Credit.create_for_dispute_won!(user:, merchant_account:, dispute:,
                                     chargedback_purchase: purchase,
                                     balance_transaction_issued_amount:,
                                     balance_transaction_holding_amount:)
      expect(user.reload.comments.count).to eq(comment_count_before_credit + 1)
      expect(user.reload.comments.last.content).to include("issued $88.90 credit")
    end

    it "applies the credit to the oldest unpaid balance" do
      old_balance = create(:balance, user:, merchant_account:, date: 10.days.ago)
      balance_before_credit = user.unpaid_balance_cents
      credit = Credit.create_for_dispute_won!(user:, merchant_account:, dispute:,
                                              chargedback_purchase: purchase,
                                              balance_transaction_issued_amount:,
                                              balance_transaction_holding_amount:)
      balance_after_credit = user.reload.unpaid_balance_cents
      expect(balance_after_credit).to eq(balance_before_credit + credit.amount_cents)
      expect(credit.balance).to eq(old_balance)
    end

    it "applies the credit to an unpaid balance for the creator's merchant account" do
      credit = Credit.create_for_dispute_won!(user:, merchant_account:, dispute:,
                                              chargedback_purchase: purchase,
                                              balance_transaction_issued_amount:,
                                              balance_transaction_holding_amount:)
      expect(credit.balance.merchant_account).to eq(merchant_account)
    end
  end

  describe "create_for_returned_payment_difference!" do
    let(:user) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user:) }
    let(:returned_payment) { create(:payment_returned) }
    let(:difference_amount_cents) { raise NotImplementedError }

    let(:credit) do
      Credit.create_for_returned_payment_difference!(
        user:,
        merchant_account:,
        returned_payment:,
        difference_amount_cents:
      )
    end

    describe "when the difference is positive" do
      let(:difference_amount_cents) { 1_00 }

      it "is for a zero amount" do
        expect(credit.amount_cents).to eq(0)
      end

      it "assigns the returned payment" do
        expect(credit.returned_payment).to eq(returned_payment)
      end

      it "creates a balance transaction with a zero issued amount" do
        expect(credit.balance_transaction.issued_amount_gross_cents).to eq(0)
        expect(credit.balance_transaction.issued_amount_net_cents).to eq(0)
      end

      it "creates a balance transaction with the difference as the holding amount" do
        expect(credit.balance_transaction.holding_amount_gross_cents).to eq(difference_amount_cents)
        expect(credit.balance_transaction.holding_amount_net_cents).to eq(difference_amount_cents)
      end

      it "does not update the balances amount_cents" do
        balance = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect { credit }.not_to change { balance.reload.amount_cents }
        expect(credit.balance).to eq(balance)
      end

      it "updates the balances holding_amount_cents" do
        balance = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect { credit }.to change { balance.reload.holding_amount_cents }
        expect(credit.balance).to eq(balance)
      end

      it "does not update the unpaid_balance_cents for users after creation" do
        expect { credit }.not_to change { user.reload.unpaid_balance_cents }
      end

      it "creates a comment after credit" do
        expect { credit }.to change { user.reload.comments.count }.by(1)
      end

      it "creates a command after credit with the returned payment id" do
        credit
        user.reload
        expect(user.comments.last.content).to include("issued adjustment due to currency conversion differences when payment #{returned_payment.id} returned")
        expect(user.comments.last.author_name).to eq("AutoCredit Returned Payment (#{returned_payment.id})")
      end

      it "applies the credit to the oldest unpaid balance" do
        old_balance_1 = create(:balance, user:, merchant_account:, date: 20.days.ago)
        old_balance_2 = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect(credit.balance).to eq(old_balance_1)
        expect(credit.balance).not_to eq(old_balance_2)
      end

      it "applies the credit to the unpaid balance for the creator's merchant account" do
        old_balance_1 = create(:balance, user:, merchant_account: create(:merchant_account), date: 20.days.ago)
        old_balance_2 = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect(credit.balance).to eq(old_balance_2)
        expect(credit.balance).not_to eq(old_balance_1)
      end
    end

    describe "when the difference is negative" do
      let(:difference_amount_cents) { -1_00 }

      it "is for a zero amount" do
        expect(credit.amount_cents).to eq(0)
      end

      it "assigns the returned payment" do
        expect(credit.returned_payment).to eq(returned_payment)
      end

      it "creates a balance transaction with a zero issued amount" do
        expect(credit.balance_transaction.issued_amount_gross_cents).to eq(0)
        expect(credit.balance_transaction.issued_amount_net_cents).to eq(0)
      end

      it "creates a balance transaction with the difference as the holding amount" do
        expect(credit.balance_transaction.holding_amount_gross_cents).to eq(difference_amount_cents)
        expect(credit.balance_transaction.holding_amount_net_cents).to eq(difference_amount_cents)
      end

      it "does not update the balances amount_cents" do
        balance = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect { credit }.not_to change { balance.reload.amount_cents }
        expect(credit.balance).to eq(balance)
      end

      it "updates the balances holding_amount_cents" do
        balance = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect { credit }.to change { balance.reload.holding_amount_cents }
        expect(credit.balance).to eq(balance)
      end

      it "does not update the unpaid_balance_cents for users after creation" do
        expect { credit }.not_to change { user.reload.unpaid_balance_cents }
      end

      it "creates a comment after credit" do
        expect { credit }.to change { user.reload.comments.count }.by(1)
      end

      it "creates a command after credit with the returned payment id" do
        credit
        user.reload
        expect(user.comments.last.content).to include("issued adjustment due to currency conversion differences when payment #{returned_payment.id} returned")
        expect(user.comments.last.author_name).to eq("AutoCredit Returned Payment (#{returned_payment.id})")
      end

      it "applies the credit to the oldest unpaid balance" do
        old_balance_1 = create(:balance, user:, merchant_account:, date: 20.days.ago)
        old_balance_2 = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect(credit.balance).to eq(old_balance_1)
        expect(credit.balance).not_to eq(old_balance_2)
      end

      it "applies the credit to the unpaid balance for the creator's merchant account" do
        old_balance_1 = create(:balance, user:, merchant_account: create(:merchant_account), date: 20.days.ago)
        old_balance_2 = create(:balance, user:, merchant_account:, date: 10.days.ago)
        expect(credit.balance).to eq(old_balance_2)
        expect(credit.balance).not_to eq(old_balance_1)
      end
    end
  end

  describe "create_for_refund_fee_retention!", :vcr do
    let!(:creator) { create(:user) }
    let!(:merchant_account) { create(:merchant_account_stripe, user: creator) }
    let!(:purchase) { create(:purchase, succeeded_at: 3.days.ago, link: create(:product, user: creator), merchant_account:) }
    let!(:refund) { create(:refund, purchase:, fee_cents: 100) }

    it "assigns the refund as fee_retention_refund" do
      expect(Stripe::Transfer).to receive(:create).and_call_original
      credit = Credit.create_for_refund_fee_retention!(refund:)
      expect(credit.fee_retention_refund).to eq(refund)
    end

    it "updates the unpaid_balance_cents for the seller" do
      expect(Stripe::Transfer).to receive(:create).and_call_original
      expect(creator.unpaid_balance_cents).to eq(0)

      credit = Credit.create_for_refund_fee_retention!(refund:)

      expect(credit.amount_cents).to eq(-33)
      expect(creator.reload.unpaid_balance_cents).to eq(-33)
    end

    it "creates a balance record after credit" do
      expect(Stripe::Transfer).to receive(:create).and_call_original
      credit = Credit.create_for_refund_fee_retention!(refund:)
      expect(credit.balance).to eq(Balance.last)
    end

    it "applies the credit to the oldest unpaid balance and not the unpaid balance from purchase date" do
      oldest_balance = create(:balance, user: creator, amount_cents: 1000, merchant_account:, date: purchase.succeeded_at.to_date - 2.days)
      create(:balance, user: creator, amount_cents: 2000, merchant_account:, date: purchase.succeeded_at.to_date)
      expect(Stripe::Transfer).to receive(:create).and_call_original
      expect(creator.unpaid_balance_cents).to eq(3000)

      credit = Credit.create_for_refund_fee_retention!(refund:)

      expect(credit.amount_cents).to eq(-33)
      expect(credit.balance).to eq(oldest_balance)
      expect(credit.balance.merchant_account).to eq(merchant_account)
      expect(credit.balance_transaction.issued_amount_net_cents).to eq(-33)
      expect(credit.balance_transaction.holding_amount_net_cents).to eq(-33)
      expect(creator.reload.unpaid_balance_cents).to eq(2967) # 3000 - 33
    end

    describe "Gumroad-controlled non-US Stripe account sales" do
      it "applies the credit to the oldest unpaid balance and not the unpaid balance from purchase date" do
        travel_to(Time.at(1681734634).utc) do
          non_us_stripe_account = create(:merchant_account, charge_processor_merchant_id: "acct_1LrgA6S47qdHFIIY", country: "AU", currency: "aud", user: creator)
          purchase = create(:purchase, succeeded_at: 3.days.ago, link: create(:product, user: creator), merchant_account: non_us_stripe_account)
          refund = create(:refund, purchase:, fee_cents: 100)
          oldest_balance = create(:balance, user: creator, merchant_account: non_us_stripe_account, amount_cents: 1000, holding_currency: "aud", date: purchase.succeeded_at.to_date - 2.days)
          create(:balance, user: creator, merchant_account: non_us_stripe_account, amount_cents: 2000,
                           holding_currency: "aud", date: purchase.succeeded_at.to_date)
          expect(Stripe::Transfer).to receive(:create_reversal).and_call_original
          expect(creator.unpaid_balance_cents).to eq(3000)

          credit = Credit.create_for_refund_fee_retention!(refund:)

          expect(credit.amount_cents).to eq(-33)
          expect(credit.balance).to eq(oldest_balance)
          expect(credit.balance.merchant_account).to eq(non_us_stripe_account)
          expect(credit.balance_transaction.issued_amount_net_cents).to eq(-33)
          expect(credit.balance_transaction.holding_amount_net_cents).to eq(-52)
          expect(creator.reload.unpaid_balance_cents).to eq(2967) # 3000 - 33
        end
      end
    end

    describe "PayPal Connect sales" do
      let(:purchase) do
        create(:purchase, succeeded_at: 3.days.ago, link: create(:product, user: creator), charge_processor_id: "paypal",
                          merchant_account: create(:merchant_account_paypal, user: creator))
      end
      let(:refund) { create(:refund, purchase:, fee_cents: 100) }

      context "when the Gumroad tax and affiliate credit are present" do
        it "returns a positive credit for the affiliate commission and taxes" do
          purchase.update!(gumroad_tax_cents: 10, affiliate_credit_cents: 15)

          credit = Credit.create_for_refund_fee_retention!(refund:)
          expect(credit.amount_cents).to eq(25)
          expect(credit.fee_retention_refund).to eq(refund)
          expect(credit.balance.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
          expect(credit.balance_transaction.issued_amount_net_cents).to eq(25)
          expect(credit.balance_transaction.holding_amount_net_cents).to eq(25)
          expect(creator.reload.unpaid_balance_cents).to eq(25)
        end
      end

      context "when the Gumroad tax and affiliate credit are not present" do
        it "does nothing and returns" do
          expect(Credit).not_to receive(:new)

          expect(Credit.create_for_refund_fee_retention!(refund:)).to be nil
        end
      end
    end

    describe "Stripe Connect sales" do
      let(:purchase) do
        create(:purchase, succeeded_at: 3.days.ago, link: create(:product, user: creator), charge_processor_id: "stripe",
                          merchant_account: create(:merchant_account_stripe_connect))
      end
      let(:refund) { create(:refund, purchase:, fee_cents: 100) }

      context "when the Gumroad tax and affiliate credit are present" do
        it "returns a positive credit for the affiliate commission and taxes" do
          purchase.update!(gumroad_tax_cents: 10, affiliate_credit_cents: 15)

          credit = Credit.create_for_refund_fee_retention!(refund:)
          expect(credit.amount_cents).to eq(25)
          expect(credit.fee_retention_refund).to eq(refund)
          expect(credit.balance.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
          expect(credit.balance_transaction.issued_amount_net_cents).to eq(25)
          expect(credit.balance_transaction.holding_amount_net_cents).to eq(25)
          expect(creator.reload.unpaid_balance_cents).to eq(25)
        end
      end

      context "when the Gumroad tax and affiliate credit are not present" do
        it "does nothing and returns" do
          expect(Credit).not_to receive(:new)

          expect(Credit.create_for_refund_fee_retention!(refund:)).to be nil
        end
      end
    end

    it "does not create a comment after credit" do
      expect do
        Credit.create_for_refund_fee_retention!(refund:)
      end.not_to change { refund.purchase.seller.comments.count }
    end

    # The retention runs after the refund has committed and the buyer has their money back,
    # so a Stripe failure must leave a durable ledger entry and a retry that only finishes
    # the Stripe side — never a second retention and never a second Stripe debit.
    describe "when the Stripe debit fails for a Gumroad-controlled non-US account" do
      let!(:merchant_account) { create(:merchant_account, user: creator, country: "AE") }
      let(:stripe_error) { Stripe::InvalidRequestError.new("Transfer reversals in BGN are no longer supported", nil) }

      before do
        allow(ErrorNotifier).to receive(:notify)
      end

      it "books the retained fee locally, reports the failure, and leaves the Stripe debit for a retry" do
        expect(StripeChargeProcessor).to receive(:debit_stripe_account_for_refund_fee).with(credit: an_instance_of(Credit)).and_raise(stripe_error)

        credit = Credit.create_for_refund_fee_retention!(refund:)

        expect(credit).to be_persisted
        expect(credit.amount_cents).to eq(-33)
        expect(credit.balance_transaction.issued_amount_net_cents).to eq(-33)
        expect(credit.balance_transaction.holding_amount_net_cents).to eq(-33)
        expect(refund.reload.retained_fee_cents).to eq(33)
        expect(refund.debited_stripe_transfer).to eq(Credit::FEE_DEBIT_PENDING_RETRY)
        expect(creator.reload.unpaid_balance_cents).to eq(-33)
        expect(ErrorNotifier).to have_received(:notify).with(stripe_error, hash_including(context: hash_including(refund_id: refund.id)))
      end

      it "retries only the Stripe debit when called again, and stops once the debit is recorded" do
        attempts = 0
        allow(StripeChargeProcessor).to receive(:debit_stripe_account_for_refund_fee) do |credit:|
          attempts += 1
          raise stripe_error if attempts == 1

          credit.fee_retention_refund.update!(debited_stripe_transfer: "trr_retry")
          33
        end

        credit = Credit.create_for_refund_fee_retention!(refund:)
        expect(refund.reload.debited_stripe_transfer).to eq(Credit::FEE_DEBIT_PENDING_RETRY)

        expect do
          expect(Credit.create_for_refund_fee_retention!(refund:)).to eq(credit)
        end.not_to change { [Credit.count, BalanceTransaction.count, creator.reload.unpaid_balance_cents] }
        expect(refund.reload.debited_stripe_transfer).to eq("trr_retry")

        expect(Credit.create_for_refund_fee_retention!(refund:)).to eq(credit)
        expect(attempts).to eq(2)
      end
    end

    describe "when re-run for a Gumroad-controlled US account" do
      let!(:merchant_account) { create(:merchant_account, user: creator, country: "US") }

      it "records the debit transfer on the refund and does not debit Stripe a second time" do
        allow(Stripe::Account).to receive(:retrieve).and_return(double(id: "acct_platform"))
        expect(Stripe::Transfer).to receive(:create)
                                      .with({ amount: 33, currency: "usd", destination: "acct_platform" },
                                            hash_including(stripe_account: merchant_account.charge_processor_merchant_id,
                                                           idempotency_key: "refund_fee_us_debit_#{refund.external_id}"))
                                      .once
                                      .and_return(double(id: "tr_us_fee_1"))

        credit = Credit.create_for_refund_fee_retention!(refund:)
        expect(refund.reload.debited_stripe_transfer).to eq("tr_us_fee_1")

        expect do
          expect(Credit.create_for_refund_fee_retention!(refund:)).to eq(credit)
        end.not_to change { [Credit.count, creator.reload.unpaid_balance_cents] }
      end

      it "does not re-debit a legacy US retention that completed without a debit marker" do
        allow(Stripe::Account).to receive(:retrieve).and_return(double(id: "acct_platform"))
        expect(Stripe::Transfer).to receive(:create)
                                      .once
                                      .and_return(double(id: "tr_us_fee_legacy"))

        credit = Credit.create_for_refund_fee_retention!(refund:)
        # Simulate pre-patch US success: ledger complete, marker never recorded.
        refund.update!(debited_stripe_transfer: nil)
        expect(credit.reload.balance_id).to be_present

        expect(Stripe::Transfer).not_to receive(:create)
        expect(Credit.create_for_refund_fee_retention!(refund:)).to eq(credit)
      end

      it "retries a US debit that failed after booking the local ledger" do
        allow(Stripe::Account).to receive(:retrieve).and_return(double(id: "acct_platform"))
        allow(ErrorNotifier).to receive(:notify)
        attempts = 0
        allow(Stripe::Transfer).to receive(:create) do
          attempts += 1
          raise Stripe::APIConnectionError, "timeout" if attempts == 1

          double(id: "tr_us_fee_retry")
        end

        credit = Credit.create_for_refund_fee_retention!(refund:)
        expect(refund.reload.debited_stripe_transfer).to eq(Credit::FEE_DEBIT_PENDING_RETRY)
        expect(credit).to be_persisted

        expect(Credit.create_for_refund_fee_retention!(refund:)).to eq(credit)
        expect(refund.reload.debited_stripe_transfer).to eq("tr_us_fee_retry")
        expect(attempts).to eq(2)
      end
    end

    describe "when a successful non-US debit retry returns a different holding amount" do
      let!(:merchant_account) { create(:merchant_account, user: creator, country: "CA", currency: "cad") }

      before do
        allow(ErrorNotifier).to receive(:notify)
        allow(StripeChargeProcessor).to receive(:get_rate).with("cad").and_return("1.33")
      end

      it "adjusts the unpaid balance holding total to the actual Stripe debit" do
        attempts = 0
        allow(StripeChargeProcessor).to receive(:debit_stripe_account_for_refund_fee) do |credit:|
          attempts += 1
          if attempts == 1
            raise Stripe::APIConnectionError, "timeout"
          end

          credit.fee_retention_refund.update!(debited_stripe_transfer: "trr_holding")
          1400
        end

        credit = Credit.create_for_refund_fee_retention!(refund:)
        expect(refund.reload.debited_stripe_transfer).to eq(Credit::FEE_DEBIT_PENDING_RETRY)
        estimated = credit.balance_transaction.holding_amount_net_cents
        expect(estimated).to be < 0

        balance_before = credit.balance.holding_amount_cents
        expect(Credit.create_for_refund_fee_retention!(refund:)).to eq(credit)
        expect(attempts).to eq(2)
        expect(refund.reload.refund_fee_holding_debit_cents).to eq(1400)
        expect(credit.balance.reload.holding_amount_cents).to eq(balance_before + (-1400 - estimated))
      end
    end
  end

  describe "create_for_balance_change_on_stripe_account!" do
    let!(:creator) { create(:user) }
    let!(:merchant_account) { create(:merchant_account, user: creator) }

    before do
      stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    end

    it "updates the unpaid_balance_cents for the seller" do
      balance_before_credit = creator.unpaid_balance_cents

      expect do
        Credit.create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: -1000, merchant_account:)
      end.to change { creator.credits.count }.by(1)

      balance_after_credit = creator.reload.unpaid_balance_cents
      credit = Credit.last
      expect(credit.amount_cents).to eq(-1000)
      expect(credit.merchant_account_id).to eq(merchant_account.id)
      expect(balance_after_credit).to eq(balance_before_credit + credit.amount_cents)
    end

    it "creates a balance record after credit" do
      credit = Credit.create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: -1000, merchant_account: create(:merchant_account), amount_cents_usd: -900)
      expect(credit.balance).to eq(Balance.last)
      expect(credit.balance.holding_amount_cents).to eq(-1000)
      expect(credit.balance.amount_cents).to eq(-900)
      expect(credit.balance.holding_currency).to eq(credit.merchant_account.currency)
    end
  end
end
