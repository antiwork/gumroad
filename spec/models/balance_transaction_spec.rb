# frozen_string_literal: true

require "spec_helper"

describe BalanceTransaction, :vcr do
  describe BalanceTransaction::Amount do
    describe "create_issued_amount_for_affiliate" do
      let(:issued_affiliate_cents) { 10_00 }
      let(:flow_of_funds) { raise "You must define `flow_of_funds`." }
      let(:amount) do
        BalanceTransaction::Amount.create_issued_amount_for_affiliate(
          flow_of_funds:,
          issued_affiliate_cents:
        )
      end

      describe "issued amount and settled amounts are the same, no merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_gross_amount: nil,
            merchant_account_net_amount: nil
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.gumroad_amount.currency)
          expect(amount.gross_cents).to eq(issued_affiliate_cents)
          expect(amount.net_cents).to eq(issued_affiliate_cents)
        end
      end

      describe "issued amount and settled amounts are the same, a merchant accounts" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 70_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.gumroad_amount.currency)
          expect(amount.gross_cents).to eq(issued_affiliate_cents)
          expect(amount.net_cents).to eq(issued_affiliate_cents)
        end
      end

      describe "issued amount and settled amounts are not the same, a merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.gumroad_amount.currency)
          expect(amount.gross_cents).to eq(issued_affiliate_cents)
          expect(amount.net_cents).to eq(issued_affiliate_cents)
        end
      end
    end

    describe "create_holding_amount_for_affiliate" do
      let(:issued_affiliate_cents) { 10_00 }
      let(:flow_of_funds) { raise "You must define `flow_of_funds`." }
      let(:amount) do
        BalanceTransaction::Amount.create_holding_amount_for_affiliate(
          flow_of_funds:,
          issued_affiliate_cents:
        )
      end

      describe "issued amount and settled amounts are the same, no merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_gross_amount: nil,
            merchant_account_net_amount: nil
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.gumroad_amount.currency)
          expect(amount.gross_cents).to eq(issued_affiliate_cents)
          expect(amount.net_cents).to eq(issued_affiliate_cents)
        end
      end

      describe "issued amount and settled amounts are the same, a merchant accounts" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 70_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.gumroad_amount.currency)
          expect(amount.gross_cents).to eq(issued_affiliate_cents)
          expect(amount.net_cents).to eq(issued_affiliate_cents)
        end
      end

      describe "issued amount and settled amounts are not the same, a merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.gumroad_amount.currency)
          expect(amount.gross_cents).to eq(issued_affiliate_cents)
          expect(amount.net_cents).to eq(issued_affiliate_cents)
        end
      end
    end

    describe "create_issued_amount_for_seller" do
      let(:issued_net_cents) { 70_00 }
      let(:flow_of_funds) { raise "You must define `flow_of_funds`." }
      let(:amount) do
        BalanceTransaction::Amount.create_issued_amount_for_seller(
          flow_of_funds:,
          issued_net_cents:
        )
      end

      describe "issued amount and settled amounts are the same, no merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_gross_amount: nil,
            merchant_account_net_amount: nil
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.issued_amount.currency)
          expect(amount.gross_cents).to eq(flow_of_funds.issued_amount.cents)
          expect(amount.net_cents).to eq(issued_net_cents)
        end
      end

      describe "issued amount and settled amounts are the same, a merchant accounts" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 70_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.issued_amount.currency)
          expect(amount.gross_cents).to eq(flow_of_funds.issued_amount.cents)
          expect(amount.net_cents).to eq(issued_net_cents)
        end
      end

      describe "issued amount and settled amounts are not the same, a merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.issued_amount.currency)
          expect(amount.gross_cents).to eq(flow_of_funds.issued_amount.cents)
          expect(amount.net_cents).to eq(issued_net_cents)
        end
      end

      describe "canonical issued amount is provided" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 70_00)
          )
        end
        let(:amount) do
          BalanceTransaction::Amount.create_issued_amount_for_seller(
            flow_of_funds:,
            issued_net_cents:,
            canonical_issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00)
          )
        end

        it "uses the canonical amount for issued gross money" do
          expect(amount.currency).to eq(Currency::USD)
          expect(amount.gross_cents).to eq(100_00)
          expect(amount.net_cents).to eq(issued_net_cents)
        end
      end
    end

    describe "create_holding_amount_for_seller" do
      let(:issued_net_cents) { 70_00 }
      let(:flow_of_funds) { raise "You must define `flow_of_funds`." }
      let(:amount) do
        BalanceTransaction::Amount.create_holding_amount_for_seller(
          flow_of_funds:,
          issued_net_cents:
        )
      end

      describe "issued amount and settled amounts are the same, no merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_gross_amount: nil,
            merchant_account_net_amount: nil
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.issued_amount.currency)
          expect(amount.gross_cents).to eq(flow_of_funds.issued_amount.cents)
          expect(amount.net_cents).to eq(issued_net_cents)
        end
      end

      describe "issued amount and settled amounts are the same, a merchant accounts" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 70_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.issued_amount.currency)
          expect(amount.gross_cents).to eq(flow_of_funds.issued_amount.cents)
          expect(amount.net_cents).to eq(issued_net_cents)
        end
      end

      describe "issued amount and settled amounts are not the same, a merchant account" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80_00)
          )
        end

        it "creates an amount" do
          expect(amount.currency).to eq(flow_of_funds.merchant_account_gross_amount.currency)
          expect(amount.currency).to eq(flow_of_funds.merchant_account_net_amount.currency)
          expect(amount.gross_cents).to eq(flow_of_funds.merchant_account_gross_amount.cents)
          expect(amount.net_cents).to eq(flow_of_funds.merchant_account_net_amount.cents)
        end
      end

      describe "canonical issued amount is provided with merchant-account holding amounts" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
            merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 70_00)
          )
        end
        let(:amount) do
          BalanceTransaction::Amount.create_holding_amount_for_seller(
            flow_of_funds:,
            issued_net_cents:,
            canonical_issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00)
          )
        end

        it "keeps real merchant-account holding money" do
          expect(amount.currency).to eq(Currency::USD)
          expect(amount.gross_cents).to eq(100_00)
          expect(amount.net_cents).to eq(70_00)
        end
      end

      # A buyer-presentment charge (buyer pays EUR) with no merchant-account leg, which is the
      # shape Gumroad-held funds produce. The two holders want opposite answers from this same
      # flow of funds, so both are pinned here — see gumroad-private#1471.
      describe "a buyer-presentment charge with no merchant-account holding amounts" do
        let(:flow_of_funds) do
          FlowOfFunds.new(
            issued_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: 90_00),
            settled_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: 90_00),
            gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
            merchant_account_gross_amount: nil,
            merchant_account_net_amount: nil
          )
        end
        let(:canonical_issued_amount) { FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00) }

        context "when Gumroad holds the funds" do
          # The Gumroad-held platform account is the userless merchant account — that is exactly
          # what StripeChargeProcessor#holder_of_funds keys on to return GUMROAD (in production
          # this is merchant_accounts.id = 1, currency USD). The explicit merchant id keeps this
          # from colliding with the sibling contexts' accounts on the uniqueness validation.
          let(:merchant_account) do
            create(:merchant_account, user: nil, currency: Currency::USD,
                                      charge_processor_merchant_id: "acct_gumroad_held_#{SecureRandom.hex(6)}")
          end
          let(:amount) do
            BalanceTransaction::Amount.create_holding_amount_for_seller(
              flow_of_funds:,
              issued_net_cents:,
              canonical_issued_amount:,
              merchant_account:
            )
          end

          # Gumroad holds this money in its own USD platform account whatever the buyer paid in.
          # Labelling it EUR made payouts reject the balance and fail the seller's entire
          # payment with currency_mismatch, correctly-labelled USD balances included.
          it "labels the balance in USD, not the buyer's presentment currency" do
            expect(merchant_account.holder_of_funds).to eq(HolderOfFunds::GUMROAD)
            expect(amount.currency).to eq(Currency::USD)
            expect(amount.gross_cents).to eq(100_00)
            expect(amount.net_cents).to eq(issued_net_cents)
          end

          # The guard the mislabelling tripped, driven directly rather than asserted by implication.
          # This is what ties the currency label to the seller's money. Payouts reject a Gumroad-held
          # balance whose holding_currency is not USD, and because is_balance_payable is true for
          # every Gumroad-held balance, one bad row is still pulled into the payout and fails the
          # whole payment — taking the seller's correctly-labelled USD balances down with it.
          it "produces a currency the payout processor's Gumroad-held check accepts" do
            expect(StripePayoutProcessor.is_balance_payable(
                     instance_double(Balance, merchant_account:, holding_currency: amount.currency)
                   )).to be(true)

            # The rejection half, so this pins the failure mode and not only the fix: a Gumroad-held
            # balance is payable whatever its currency, so it is the currency comparison in
            # #prepare_payment_and_set_amount that must keep refusing the buyer's currency. If that
            # ever stopped being true, mislabelling would go silent instead of failing loudly.
            expect(StripePayoutProcessor.is_balance_payable(
                     instance_double(Balance, merchant_account:, holding_currency: Currency::EUR)
                   )).to be(true)
            expect(Currency::EUR).not_to eq(amount.currency)
          end
        end

        context "when the seller's own connected Stripe account holds the funds" do
          let(:merchant_account) { create(:merchant_account_stripe_connect, currency: Currency::EUR) }
          let(:amount) do
            BalanceTransaction::Amount.create_holding_amount_for_seller(
              flow_of_funds:,
              issued_net_cents:,
              canonical_issued_amount:,
              merchant_account:
            )
          end

          # Unchanged behaviour, and the reason the fix cannot simply drop this branch: here the
          # money genuinely settles in the connected account's own currency.
          it "keeps labelling the balance in the settled currency" do
            expect(merchant_account.holder_of_funds).to_not eq(HolderOfFunds::GUMROAD)
            expect(amount.currency).to eq(Currency::EUR)
            expect(amount.gross_cents).to eq(90_00)
            expect(amount.net_cents).to eq(issued_net_cents)
          end
        end

        context "when a Stripe-held account holds the funds" do
          # Explicit merchant id for the same uniqueness reason as the Gumroad-held context above.
          let(:merchant_account) do
            create(:merchant_account, currency: Currency::EUR,
                                      charge_processor_merchant_id: "acct_stripe_held_#{SecureRandom.hex(6)}")
          end
          let(:amount) do
            BalanceTransaction::Amount.create_holding_amount_for_seller(
              flow_of_funds:,
              issued_net_cents:,
              canonical_issued_amount:,
              merchant_account:
            )
          end

          # A Gumroad-managed account belonging to a seller: Stripe holds the funds in that
          # account's own currency, so the settled currency is the right label.
          it "keeps labelling the balance in the settled currency" do
            expect(merchant_account.holder_of_funds).to eq(HolderOfFunds::STRIPE)
            expect(amount.currency).to eq(Currency::EUR)
          end
        end

        context "when no merchant account is given" do
          let(:amount) do
            BalanceTransaction::Amount.create_holding_amount_for_seller(
              flow_of_funds:,
              issued_net_cents:,
              canonical_issued_amount:
            )
          end

          it "keeps the pre-existing settled-currency behaviour" do
            expect(amount.currency).to eq(Currency::EUR)
          end
        end
      end
    end
  end

  describe "create!" do
    let(:user) { create(:user) }
    let(:link) { create(:product, user:) }
    let(:merchant_account) { create(:merchant_account) }

    describe "for a purchase" do
      let!(:purchase) { travel_to(1.day.ago) { create(:purchase, link:, seller: user, merchant_account:) } }

      let(:balance_transaction) do
        BalanceTransaction.create!(
          user:,
          merchant_account:,
          purchase:,
          issued_amount: BalanceTransaction::Amount.new(
            currency: Currency::USD,
            gross_cents: 100_00,
            net_cents: 88_90
          ),
          holding_amount: BalanceTransaction::Amount.new(
            currency: Currency::CAD,
            gross_cents: 110_00,
            net_cents: 97_79
          )
        )
      end

      it "saves all the associations on the balance_transaction record" do
        Balance.destroy_all
        expect(balance_transaction.user).to eq(user)
        expect(balance_transaction.merchant_account).to eq(merchant_account)
        expect(balance_transaction.purchase).to eq(purchase)
        expect(balance_transaction.refund).to eq(nil)
        expect(balance_transaction.dispute).to eq(nil)
        expect(balance_transaction.credit).to eq(nil)
      end

      it "saves all the amounts on the balance_transaction record" do
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_gross_cents).to eq(100_00)
        expect(balance_transaction.issued_amount_net_cents).to eq(88_90)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_gross_cents).to eq(110_00)
        expect(balance_transaction.holding_amount_net_cents).to eq(97_79)
      end

      it "results in a balance object having the new balance" do
        expect { balance_transaction }.to change { user.unpaid_balance_cents }.by(88_90)
      end

      describe "balance update" do
        before { Balance.destroy_all }

        describe "no balances exist" do
          it "creates a balance for the day of purchase and update its amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end

        describe "unpaid balance exists on another day, but not the day of purchase" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (purchase.succeeded_at + 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a balance for the day of purchase and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end

        describe "paid balance exists on another day, but not the day of purchase" do
          let(:balance) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: (purchase.succeeded_at + 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a balance for the day of purchase and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end

        describe "unpaid balance exists on day of purchase, but with different holding currency" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::USD,
              holding_amount_cents: 100_00
            )
          end

          before do
            balance
          end

          it "creates a balance for the day of purchase and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end

        describe "unpaid balance exists on day of purchase" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(188_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(207_79)
          end
        end

        describe "processing balance exists on day of purchase" do
          let(:balance) do
            create(
              :balance,
              state: "processing",
              user:,
              merchant_account:,
              date: purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a new unpaid balance record" do
            expect { balance_transaction }.to change { user.balances.count }.by(1)
            expect(balance_transaction.balance).not_to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end

        describe "paid balance exists on day of purchase" do
          let(:balance) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a new unpaid balance record" do
            expect { balance_transaction }.to change { user.balances.count }.by(1)
            expect(balance_transaction.balance).not_to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end
      end
    end

    describe "for a refund" do
      let!(:purchase) { travel_to(30.days.ago) { create(:purchase, link:, seller: user, merchant_account:) } }
      let!(:refund) { travel_to(1.day.ago) { create(:refund, purchase:) } }
      let(:balance_transaction) do
        BalanceTransaction.create!(
          user:,
          merchant_account:,
          refund:,
          issued_amount: BalanceTransaction::Amount.new(
            currency: Currency::USD,
            gross_cents: -100_00,
            net_cents: -88_90
          ),
          holding_amount: BalanceTransaction::Amount.new(
            currency: Currency::CAD,
            gross_cents: -110_00,
            net_cents: -97_79
          )
        )
      end

      it "saves all the associations on the balance_transaction record" do
        expect(balance_transaction.user).to eq(user)
        expect(balance_transaction.merchant_account).to eq(merchant_account)
        expect(balance_transaction.purchase).to eq(nil)
        expect(balance_transaction.refund).to eq(refund)
        expect(balance_transaction.dispute).to eq(nil)
        expect(balance_transaction.credit).to eq(nil)
      end

      it "saves all the amounts on the balance_transaction record" do
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_gross_cents).to eq(-100_00)
        expect(balance_transaction.issued_amount_net_cents).to eq(-88_90)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_gross_cents).to eq(-110_00)
        expect(balance_transaction.holding_amount_net_cents).to eq(-97_79)
      end

      it "results in a balance object having the new balance" do
        expect { balance_transaction }.to change { user.unpaid_balance_cents }.by(-88_90)
      end

      describe "balance update" do
        describe "no balances exist" do
          it "creates a balance for the day of refund and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(refund.created_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end

        describe "unpaid balance exists on day of refund's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: refund.purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(refund.purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(11_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(12_21)
          end
        end

        describe "unpaid balance exists on another day, but not the day of refund's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (refund.purchase.succeeded_at + 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((refund.purchase.succeeded_at + 2.days).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(11_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(12_21)
          end
        end

        describe "paid balance exists on day of purchase, and unpaid balance exists on the day of refund" do
          let(:balance_1) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end
          let(:balance_2) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (refund.created_at - 1.day).to_date,
              currency: Currency::USD,
              amount_cents: 200_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 220_00
            )
          end
          let(:balance_3) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: refund.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 300_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 330_00
            )
          end

          before do
            balance_1
            balance_2
            balance_3
          end

          it "creates a balance for the earliest unpaid balance and update it's amounts" do
            expect(balance_transaction.balance).to eq(balance_2)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((refund.created_at - 1.day).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(111_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(122_21)
          end
        end

        describe "processing balance exists on day of refund's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "processing",
              user:,
              merchant_account:,
              date: refund.purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a balance at the date of the refund and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(refund.created_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end

        describe "paid balance exists on day of refund's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: refund.purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a balance for the date of the refund and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(refund.created_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end
      end
    end

    describe "for a dispute" do
      let!(:purchase) { travel_to(30.days.ago) { create(:purchase, link:, seller: user, merchant_account:) } }
      let!(:dispute) { travel_to(1.day.ago) { create(:dispute_formalized, purchase:) } }
      let(:balance_transaction) do
        BalanceTransaction.create!(
          user:,
          merchant_account:,
          dispute:,
          issued_amount: BalanceTransaction::Amount.new(
            currency: Currency::USD,
            gross_cents: -100_00,
            net_cents: -88_90
          ),
          holding_amount: BalanceTransaction::Amount.new(
            currency: Currency::CAD,
            gross_cents: -110_00,
            net_cents: -97_79
          )
        )
      end

      it "saves all the associations on the balance_transaction record" do
        expect(balance_transaction.user).to eq(user)
        expect(balance_transaction.merchant_account).to eq(merchant_account)
        expect(balance_transaction.purchase).to eq(nil)
        expect(balance_transaction.refund).to eq(nil)
        expect(balance_transaction.dispute).to eq(dispute)
        expect(balance_transaction.credit).to eq(nil)
      end

      it "saves all the amounts on the balance_transaction record" do
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_gross_cents).to eq(-100_00)
        expect(balance_transaction.issued_amount_net_cents).to eq(-88_90)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_gross_cents).to eq(-110_00)
        expect(balance_transaction.holding_amount_net_cents).to eq(-97_79)
      end

      it "results in a balance object having the new balance" do
        expect { balance_transaction }.to change { user.unpaid_balance_cents }.by(-88_90)
      end

      describe "balance update" do
        describe "no balances exist" do
          it "creates a balance for the day of dispute and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.formalized_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end

        describe "unpaid balance exists on day of dispute's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: dispute.purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.purchase.succeeded_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(11_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(12_21)
          end
        end

        describe "unpaid balance exists on another day, but not the day of dispute's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (dispute.purchase.succeeded_at + 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((dispute.purchase.succeeded_at + 2.days).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(11_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(12_21)
          end
        end

        describe "paid balance exists on day of purchase, and unpaid balance exists on the day of dispute" do
          let(:balance_1) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end
          let(:balance_2) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (dispute.formalized_at - 1.day).to_date,
              currency: Currency::USD,
              amount_cents: 200_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 220_00
            )
          end
          let(:balance_3) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: dispute.formalized_at.to_date,
              currency: Currency::USD,
              amount_cents: 300_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 330_00
            )
          end

          before do
            balance_1
            balance_2
            balance_3
          end

          it "creates a balance for the earliest unpaid balance and update it's amounts" do
            expect(balance_transaction.balance).to eq(balance_2)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((dispute.formalized_at - 1.day).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(111_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(122_21)
          end
        end

        describe "processing balance exists on day of dispute's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "processing",
              user:,
              merchant_account:,
              date: dispute.purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a balance at the date of the dispute and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.formalized_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end

        describe "paid balance exists on day of dispute's purchase" do
          let(:balance) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: dispute.purchase.succeeded_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            balance
          end

          it "creates a balance for the date of the dispute and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.formalized_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end
      end
    end

    describe "for a dispute on combined charge" do
      let!(:charge) { travel_to(30.days.ago) { create(:charge, seller: user, merchant_account:) } }
      let!(:purchase_1) { travel_to(30.days.ago) { create(:purchase, link: create(:product, user:), seller: user, merchant_account:) } }
      let!(:purchase_2) { travel_to(30.days.ago) { create(:purchase, link: create(:product, user:), seller: user, merchant_account:) } }
      let!(:purchase_3) { travel_to(30.days.ago) { create(:purchase, link: create(:product, user:), seller: user, merchant_account:) } }
      let!(:dispute) { travel_to(1.day.ago) { create(:dispute_formalized_on_charge, charge:) } }

      let(:balance_transaction) do
        BalanceTransaction.create!(
          user:,
          merchant_account:,
          dispute:,
          issued_amount: BalanceTransaction::Amount.new(
            currency: Currency::USD,
            gross_cents: -100_00,
            net_cents: -88_90
          ),
          holding_amount: BalanceTransaction::Amount.new(
            currency: Currency::CAD,
            gross_cents: -110_00,
            net_cents: -97_79
          )
        )
      end

      before do
        charge.purchases << purchase_1
        charge.purchases << purchase_2
        charge.purchases << purchase_3
      end

      it "saves all the associations on the balance_transaction record" do
        expect(balance_transaction.user).to eq(user)
        expect(balance_transaction.merchant_account).to eq(merchant_account)
        expect(balance_transaction.purchase).to eq(nil)
        expect(balance_transaction.refund).to eq(nil)
        expect(balance_transaction.dispute).to eq(dispute)
        expect(balance_transaction.credit).to eq(nil)
      end

      it "saves all the amounts on the balance_transaction record" do
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_gross_cents).to eq(-100_00)
        expect(balance_transaction.issued_amount_net_cents).to eq(-88_90)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_gross_cents).to eq(-110_00)
        expect(balance_transaction.holding_amount_net_cents).to eq(-97_79)
      end

      it "results in a balance object having the new balance" do
        expect { balance_transaction }.to change { user.unpaid_balance_cents }.by(-88_90)
      end

      describe "balance update" do
        describe "no balances exist" do
          it "creates a balance for the day of dispute and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.formalized_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end

        describe "unpaid balance exists on day of dispute's charge" do
          let!(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: dispute.charge.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.charge.created_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(11_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(12_21)
          end
        end

        describe "unpaid balance exists on another day, but not the day of dispute's charge" do
          let!(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (dispute.charge.created_at + 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((dispute.charge.created_at + 2.days).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(11_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(12_21)
          end
        end

        describe "paid balance exists on day of charge, and unpaid balance exists on the day of dispute" do
          let!(:balance_1) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: charge.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end
          let!(:balance_2) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (dispute.formalized_at - 1.day).to_date,
              currency: Currency::USD,
              amount_cents: 200_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 220_00
            )
          end
          let!(:balance_3) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: dispute.formalized_at.to_date,
              currency: Currency::USD,
              amount_cents: 300_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 330_00
            )
          end

          it "creates a balance for the earliest unpaid balance and update it's amounts" do
            expect(balance_transaction.balance).to eq(balance_2)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((dispute.formalized_at - 1.day).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(111_10)
            expect(balance_transaction.balance.holding_amount_cents).to eq(122_21)
          end
        end

        describe "processing balance exists on day of dispute's charge" do
          let!(:balance) do
            create(
              :balance,
              state: "processing",
              user:,
              merchant_account:,
              date: dispute.charge.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          it "creates a balance at the date of the dispute and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.formalized_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end

        describe "paid balance exists on day of dispute's charge" do
          let!(:balance) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: dispute.charge.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          it "creates a balance for the date of the dispute and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(dispute.formalized_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(-88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(-97_79)
          end
        end
      end
    end

    describe "for a credit" do
      let(:credit) { create(:credit, user:, merchant_account:) }
      let(:balance_transaction) do
        BalanceTransaction.create!(
          user:,
          merchant_account:,
          credit:,
          issued_amount: BalanceTransaction::Amount.new(
            currency: Currency::USD,
            gross_cents: 100_00,
            net_cents: 88_90
          ),
          holding_amount: BalanceTransaction::Amount.new(
            currency: Currency::CAD,
            gross_cents: 110_00,
            net_cents: 97_79
          )
        )
      end

      it "saves all the associations on the balance_transaction record" do
        expect(balance_transaction.user).to eq(user)
        expect(balance_transaction.merchant_account).to eq(merchant_account)
        expect(balance_transaction.purchase).to eq(nil)
        expect(balance_transaction.refund).to eq(nil)
        expect(balance_transaction.dispute).to eq(nil)
        expect(balance_transaction.credit).to eq(credit)
      end

      it "saves all the amounts on the balance_transaction record" do
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_gross_cents).to eq(100_00)
        expect(balance_transaction.issued_amount_net_cents).to eq(88_90)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_gross_cents).to eq(110_00)
        expect(balance_transaction.holding_amount_net_cents).to eq(97_79)
      end

      it "results in a balance object having the new balance" do
        expect { balance_transaction }.to change { user.unpaid_balance_cents }.by(88_90)
      end

      describe "balance update" do
        describe "no balances exist" do
          it "creates a balance for the day of credit and update it's amounts" do
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(credit.created_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(88_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
          end
        end

        describe "unpaid balance exists on another day, but not the day of credit" do
          let!(:balance) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (credit.created_at - 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((credit.created_at - 2.days).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(188_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(207_79)
          end
        end

        describe "unpaid balance exists on another day, and on the day of the credit" do
          let!(:balance_1) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: (credit.created_at - 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end
          let!(:balance_2) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: credit.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 200_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 220_00
            )
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance_1)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq((credit.created_at - 2.days).to_date)
            expect(balance_transaction.balance.amount_cents).to eq(188_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(207_79)
          end
        end

        describe "paid balance exists on another day, and an unpaid balance on the day of the credit" do
          let!(:balance_1) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: (credit.created_at - 2.days).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end
          let!(:balance_2) do
            create(
              :balance,
              state: "unpaid",
              user:,
              merchant_account:,
              date: credit.created_at.to_date,
              currency: Currency::USD,
              amount_cents: 200_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 220_00
            )
          end

          it "updates the balance's amounts" do
            expect(balance_transaction.balance).to eq(balance_2)
            expect(balance_transaction.balance.user).to eq(user)
            expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
            expect(balance_transaction.balance.date).to eq(credit.created_at.to_date)
            expect(balance_transaction.balance.amount_cents).to eq(288_90)
            expect(balance_transaction.balance.holding_amount_cents).to eq(317_79)
          end
        end

        describe "for a returned payment" do
          let!(:returned_payment) { create(:payment, user:) }
          let!(:credit) { create(:credit, user:, merchant_account:, returned_payment:) }
          let!(:paid_balance) do
            create(
              :balance,
              state: "paid",
              user:,
              merchant_account:,
              date: (credit.created_at - 3.weeks).to_date,
              currency: Currency::USD,
              amount_cents: 100_00,
              holding_currency: Currency::CAD,
              holding_amount_cents: 110_00
            )
          end

          before do
            returned_payment.balances = [create(:balance, user:, date: 6.days.ago),
                                         create(:balance, user:, date: 5.days.ago)]
          end

          describe "when an unpaid balance against the merchant account already exists" do
            let!(:balance_2) do
              create(
                :balance,
                state: "unpaid",
                user:,
                merchant_account:,
                date: (credit.created_at - 2.weeks).to_date,
                currency: Currency::USD,
                amount_cents: 200_00,
                holding_currency: Currency::CAD,
                holding_amount_cents: 220_00
              )
            end

            let!(:balance_3) do
              create(
                :balance,
                state: "unpaid",
                user:,
                merchant_account:,
                date: (credit.created_at - 1.week).to_date,
                currency: Currency::USD,
                amount_cents: 200_00,
                holding_currency: Currency::CAD,
                holding_amount_cents: 220_00
              )
            end

            it "updates the earliest unpaid balance for the merchant account" do
              expect(balance_transaction.balance).to eq(balance_2)
              expect(balance_transaction.balance.user).to eq(user)
              expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
              expect(balance_transaction.balance.date).to eq((credit.created_at - 2.weeks).to_date)
              expect(balance_transaction.balance.amount_cents).to eq(288_90)
              expect(balance_transaction.balance.holding_amount_cents).to eq(317_79)
            end
          end

          describe "when no unpaid balance against the merchant account exists" do
            it "creates a new balance for the date of the earliest balance in the returned payment" do
              expect(user.unpaid_balances.where(merchant_account: credit.merchant_account)).to be_empty

              expect(balance_transaction.balance).to eq(user.unpaid_balances.where(merchant_account: credit.merchant_account).last)
              expect(user.unpaid_balances.where(merchant_account: credit.merchant_account).last).to be_present
              expect(balance_transaction.balance.user).to eq(user)
              expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
              expect(balance_transaction.balance.date).to eq(6.days.ago.to_date)
              expect(balance_transaction.balance.amount_cents).to eq(88_90)
              expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
            end

            describe "when the returned payment does not include any balances" do
              it "creates a new balance record with same date as credit creation date" do
                returned_payment.update!(balances: [])

                expect(user.unpaid_balances.where(merchant_account: credit.merchant_account)).to be_empty
                expect(returned_payment.balances).to be_empty

                expect(balance_transaction.balance).to eq(user.unpaid_balances.where(merchant_account: credit.merchant_account).last)
                expect(user.unpaid_balances.where(merchant_account: credit.merchant_account).last).to be_present
                expect(balance_transaction.balance.user).to eq(user)
                expect(balance_transaction.balance.merchant_account).to eq(merchant_account)
                expect(balance_transaction.balance.date).to eq(credit.created_at.to_date)
                expect(balance_transaction.balance.amount_cents).to eq(88_90)
                expect(balance_transaction.balance.holding_amount_cents).to eq(97_79)
              end
            end
          end
        end
      end
    end
  end

  describe "#update_balance!" do
    let(:user) { create(:user) }
    let(:link) { create(:product, user:) }
    let(:merchant_account) { create(:merchant_account) }
    let!(:purchase) { travel_to(1.day.ago) { create(:purchase, link:, seller: user, merchant_account:) } }

    let(:balance_transaction) do
      BalanceTransaction.create!(
        user:,
        merchant_account:,
        purchase:,
        issued_amount: BalanceTransaction::Amount.new(
          currency: Currency::USD,
          gross_cents: 100_00,
          net_cents: 88_90
        ),
        holding_amount: BalanceTransaction::Amount.new(
          currency: Currency::USD,
          gross_cents: 100_00,
          net_cents: 88_90
        )
      )
    end

    context "when a LockWaitTimeout occurs" do
      it "retries and succeeds" do
        call_count = 0
        original_with_lock = Balance.instance_method(:with_lock)

        allow_any_instance_of(Balance).to receive(:with_lock) do |balance, &block|
          call_count += 1
          if call_count == 1
            raise ActiveRecord::LockWaitTimeout.new("Mysql2::Error::TimeoutError: Lock wait timeout exceeded; try restarting transaction")
          end
          original_with_lock.bind_call(balance, &block)
        end

        allow_any_instance_of(BalanceTransaction).to receive(:sleep)

        expect { balance_transaction }.to change { user.unpaid_balance_cents }.by(88_90)
        expect(call_count).to eq(2)
      end

      it "raises after exhausting retries" do
        allow_any_instance_of(Balance).to receive(:with_lock).and_raise(
          ActiveRecord::LockWaitTimeout.new("Mysql2::Error::TimeoutError: Lock wait timeout exceeded; try restarting transaction")
        )
        allow_any_instance_of(BalanceTransaction).to receive(:sleep)

        expect { balance_transaction }.to raise_error(ActiveRecord::LockWaitTimeout)
      end
    end
  end
end
