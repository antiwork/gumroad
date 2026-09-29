# frozen_string_literal: true

require "spec_helper"

# Gumroad-held `holding_*` fields record the USD liability used for payouts, not Stripe's
# settlement currency. Exercise the booking methods and payout guards together: an Amount's
# currency alone does not establish that the resulting balance is payable.
describe "Gumroad-held presentment balance booking", :vcr do
  # The Gumroad-held platform account: userless, which is what StripeChargeProcessor#holder_of_funds
  # keys on to return GUMROAD (in production this is merchant_accounts.id = 1, currency USD).
  #
  # The processor merchant id is given explicitly rather than left to the factory sequence. Userless
  # Stripe accounts are uniqueness-validated on that column, the sequence starts at "000000001" in
  # every process, and the Minitest fixture suite keeps a permanent `gumroad_stripe` row on exactly
  # that id — so whichever example happens to draw the first sequence value collides with it.
  let!(:gumroad_merchant_account) do
    create(:merchant_account, user: nil, currency: Currency::USD,
                              charge_processor_merchant_id: "acct_gumroad_held_#{SecureRandom.hex(6)}")
  end
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 100_00) }

  # Set the settlement currency explicitly so coverage does not depend on a cassette's flow.
  # Gumroad-held charges have no destination payment, so the merchant-account legs are nil.
  def build_presentment_purchase(settled_currency: Currency::EUR, settled_cents: 90_00, with_fx_quote: false)
    purchase = create(:purchase, seller:, link: product, price_cents: 100_00, fee_cents: 30_00,
                                 displayed_price_currency_type: Currency::EUR,
                                 merchant_account: gumroad_merchant_account)

    charge_presentment_attrs = {
      processor: StripeChargeProcessor.charge_processor_id,
      presentment_currency: Currency::EUR,
      presentment_total_cents: 90_00,
      presentment_gumroad_amount_cents: 9_00,
    }
    # Settlement can stay in EUR without an FX quote; the holding liability still uses USD.
    unless with_fx_quote
      charge_presentment_attrs.merge!(stripe_fx_quote_id: nil, stripe_fx_quote_expires_at: nil, fx_rate: nil)
    end
    # The charge is built explicitly against the Gumroad-held account. Left to the factory it builds
    # its own `create(:merchant_account)`, which draws the first value of the merchant-id sequence
    # and collides with the `gumroad_stripe` fixture row the Minitest suite keeps in this database.
    charge_presentment = create(:charge_presentment,
                                charge: create(:charge, seller:, merchant_account: gumroad_merchant_account),
                                **charge_presentment_attrs)

    create(:purchase_presentment, purchase:, charge_presentment:,
                                  processor: StripeChargeProcessor.charge_processor_id,
                                  presentment_currency: Currency::EUR,
                                  presentment_price_cents: 81_00,
                                  presentment_tip_cents: 0,
                                  presentment_seller_tax_cents: 0,
                                  presentment_gumroad_tax_cents: 9_00,
                                  presentment_shipping_cents: 0,
                                  presentment_total_cents: 90_00,
                                  presentment_gumroad_amount_cents: 9_00)

    purchase.reload
    purchase.flow_of_funds = FlowOfFunds.new(
      issued_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: 90_00),
      settled_amount: FlowOfFunds::Amount.new(currency: settled_currency, cents: settled_cents),
      gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30_00),
      merchant_account_gross_amount: nil,
      merchant_account_net_amount: nil
    )
    purchase
  end

  describe "a EUR purchase with no Stripe FX quote" do
    let(:purchase) { build_presentment_purchase }

    it "books the purchase against the Gumroad-held account with no FX quote, which is the shape under test" do
      expect(purchase.merchant_account.holder_of_funds).to eq(HolderOfFunds::GUMROAD)
      expect(purchase.purchase_presentment.charge_presentment.stripe_fx_quote_id).to be_nil
      expect(purchase.purchase_presentment.presentment_currency).to eq(Currency::EUR)
      # A presentment row supplies the canonical amount even without an FX quote.
      expect(purchase.send(:presentment_canonical_issued_amount).currency).to eq(Currency::USD)
    end

    it "records the seller's balance transaction entirely in USD" do
      purchase.increment_sellers_balance!
      balance_transaction = purchase.reload.purchase_success_balance.balance_transactions.find_by(user: seller)

      # Issued: the canonical USD amount the buyer's payment came to in Gumroad's books.
      expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.issued_amount_gross_cents).to eq(purchase.total_transaction_cents)

      # Holding: Gumroad's liability, and the fields that decide payability. All three USD, and the
      # gross is the canonical issued amount rather than the EUR figure Stripe settled.
      expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.holding_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(balance_transaction.holding_amount_net_cents).to eq(purchase.payment_cents)

      expect(balance_transaction.holding_amount_currency).to_not eq(Currency::EUR)
      expect(balance_transaction.holding_amount_gross_cents).to_not eq(90_00)
    end

    it "records the seller's balance entirely in USD" do
      purchase.increment_sellers_balance!
      balance = purchase.reload.purchase_success_balance

      expect(balance.merchant_account).to eq(gumroad_merchant_account)
      expect(balance.currency).to eq(Currency::USD)
      expect(balance.holding_currency).to eq(Currency::USD)
      expect(balance.holding_amount_cents).to eq(balance.amount_cents)
    end

    # The consequence, driven through both payout processors rather than inferred from the currency.
    # They fail in different ways and only one of them is visible, which is why both are here.
    it "produces a balance both payout processors will pay" do
      purchase.increment_sellers_balance!
      balance = purchase.reload.purchase_success_balance

      # Stripe: is_balance_payable admits every Gumroad-held balance regardless of currency, so it
      # cannot be the assertion — the rejection lands one step later, in the aggregate guard, and
      # takes down the seller's *whole* payment including their correctly-labelled USD balances.
      #
      # The seller needs a payout destination for the guard to be reached at all, and the seller has
      # to be reloaded after it is created: `User#stripe_account` walks the `merchant_accounts`
      # association, which is already loaded and cached by the purchase built above.
      create(:merchant_account, user: seller, currency: Currency::USD,
                                charge_processor_merchant_id: "acct_seller_#{SecureRandom.hex(6)}")
      payment = create(:payment, user: seller.reload, processor: PayoutProcessorType::STRIPE)

      # Everything past the currency guard moves real money — it transfers the Gumroad-held funds
      # into the seller's Stripe account — so the transfer is stubbed rather than recorded. That
      # keeps this example free of any HTTP: a cassette would have to match a Stripe account id
      # that is randomised per run, and re-recording it would make a live transfer. The stub is
      # also the assertion that the guard passed, since the guard returns before reaching it.
      transferred = nil
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**kwargs|
        transferred = kwargs
        raise "reached the transfer, which is all this example needs to know"
      end

      begin
        StripePayoutProcessor.prepare_payment_and_set_amount(payment, [balance])
      rescue StandardError
        nil
      end

      # The guard passed: execution got as far as transferring, in USD, the amount this balance holds.
      expect(transferred).to be_present
      expect(transferred[:currency]).to eq(Currency::USD)
      expect(transferred[:amount_cents]).to eq(balance.holding_amount_cents)

      # The transfer stub stops after the currency guard, so overall payout success is not asserted.
      expect(payment.failure_reason).to_not eq(Payment::FailureReason::CURRENCY_MISMATCH)

      # PayPal: the opposite failure mode, and the one with no error to notice. is_balance_payable
      # requires USD, so a mislabelled row is dropped here, before any payment object exists — the
      # seller is quietly short-paid and nothing anywhere records a failure. Unlike Stripe's, this
      # one IS currency-aware, so it is the right thing to assert directly.
      expect(PaypalPayoutProcessor.is_balance_payable(balance)).to eq(true)
    end

    # Load-bearing in the direction that matters: a EUR-labelled row is what the two processors
    # reject, so the spec above is asserting a real property and not a tautology.
    it "would be unpayable on both processors if the balance carried the buyer's currency" do
      purchase.increment_sellers_balance!
      balance = purchase.reload.purchase_success_balance
      balance.update_columns(holding_currency: Currency::EUR)

      create(:merchant_account, user: seller, currency: Currency::USD,
                                charge_processor_merchant_id: "acct_seller_#{SecureRandom.hex(6)}")
      payment = create(:payment, user: seller.reload, processor: PayoutProcessorType::STRIPE)
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(payment, [balance.reload])
      expect(payment.failure_reason).to eq(Payment::FailureReason::CURRENCY_MISMATCH)
      expect(errors.first).to include("balances [#{balance.id}] have")

      expect(PaypalPayoutProcessor.is_balance_payable(balance)).to eq(false)
    end
  end

  describe "a refund of a EUR purchase with no Stripe FX quote" do
    let(:purchase) { build_presentment_purchase }

    it "books the negative leg in USD too" do
      purchase.increment_sellers_balance!

      refund_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: -90_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: -90_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -30_00),
        merchant_account_gross_amount: nil,
        merchant_account_net_amount: nil
      )
      refund = create(:refund, purchase:, amount_cents: purchase.price_cents,
                               total_transaction_cents: purchase.total_transaction_cents,
                               fee_cents: purchase.fee_cents)

      purchase.decrement_balance_for_refund_or_chargeback!(refund_flow_of_funds, refund:)
      balance_transaction = purchase.reload.purchase_refund_balance.balance_transactions
                                   .where(user: seller).where.not(refund_id: nil).last

      expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.holding_amount_net_cents).to be < 0
      expect(balance_transaction.holding_amount_net_cents).to eq(balance_transaction.issued_amount_net_cents)

      # Currency keys the balance; a EUR negative leg would not offset the USD credit.
      expect(purchase.purchase_refund_balance.holding_currency).to eq(Currency::USD)
    end
  end

  describe "a chargeback of a EUR purchase with no Stripe FX quote" do
    let(:purchase) { build_presentment_purchase }

    it "books the negative leg in USD too" do
      purchase.increment_sellers_balance!

      dispute_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: -90_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: -90_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -30_00),
        merchant_account_gross_amount: nil,
        merchant_account_net_amount: nil
      )
      dispute = create(:dispute_formalized, purchase:)

      purchase.decrement_balance_for_refund_or_chargeback!(dispute_flow_of_funds, dispute:)
      balance_transaction = purchase.reload.purchase_chargeback_balance.balance_transactions
                                   .where(user: seller).where.not(dispute_id: nil).last

      expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.holding_amount_net_cents).to be < 0
      expect(purchase.purchase_chargeback_balance.holding_currency).to eq(Currency::USD)
    end
  end

  # Stripe's USD settlement can differ from the canonical issued gross because of its FX spread.
  # The holding gross follows the canonical amount; only the holding net accrues to the balance.
  describe "a quote-backed presentment charge that Stripe converted to USD" do
    # Stripe settled 96_00 USD after converting from the buyer's EUR; Gumroad's canonical issued
    # amount is the 100_00 the product was listed at. The two differ, which is what makes this
    # spec able to tell them apart.
    let(:purchase) { build_presentment_purchase(settled_currency: Currency::USD, settled_cents: 96_00, with_fx_quote: true) }

    it "records the canonical issued gross, not Stripe's settled figure" do
      expect(purchase.purchase_presentment.charge_presentment.stripe_fx_quote_id).to be_present

      purchase.increment_sellers_balance!
      balance_transaction = purchase.reload.purchase_success_balance.balance_transactions.find_by(user: seller)

      expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.holding_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(balance_transaction.holding_amount_gross_cents).to_not eq(96_00)
      # The net — the only holding field that accumulates into the balance, and therefore the only
      # one that could move money — is unchanged by this.
      expect(balance_transaction.holding_amount_net_cents).to eq(purchase.payment_cents)
      expect(purchase.purchase_success_balance.holding_amount_cents).to eq(purchase.purchase_success_balance.amount_cents)
    end
  end

  # Affiliate credits are USD liabilities even when the seller's destination charge is in EUR.
  describe "an affiliate's share of a EUR charge into the seller's own Stripe account" do
    let(:seller_account) do
      create(:merchant_account, user: seller, currency: Currency::EUR,
                                charge_processor_merchant_id: "acct_seller_held_#{SecureRandom.hex(6)}")
    end
    let(:affiliate_user) { create(:affiliate_user) }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 10_00, products: [product]) }
    let(:affiliate_cents) { purchase.affiliate_credit_cents }

    # Deliberately no purchase_presentment: that is the case with nothing but the flow of funds
    # to take a currency from.
    let(:purchase) do
      purchase = create(:purchase, seller:, link: product, price_cents: 100_00, fee_cents: 10_00,
                                   merchant_account: seller_account, affiliate:)
      purchase.flow_of_funds = eur_flow_of_funds(1)
      purchase
    end

    # StripeCharge#build_flow_of_funds for a transfer_data[amount] destination charge: gumroad_amount
    # is in the charge currency, the merchant-account legs in the connected account's.
    def eur_flow_of_funds(sign)
      FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: sign * 90_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: sign * 90_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: sign * 9_00),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: sign * 81_00),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::EUR, cents: sign * 78_00)
      )
    end

    def affiliate_success_transaction
      purchase.balance_transactions.find_by(user: affiliate_user)
    end

    it "books the affiliate's share in USD on the Gumroad-held account" do
      purchase.increment_sellers_balance!
      balance_transaction = affiliate_success_transaction

      expect(balance_transaction.merchant_account.holder_of_funds).to eq(HolderOfFunds::GUMROAD)
      expect(balance_transaction).to have_attributes(
        issued_amount_currency: Currency::USD, issued_amount_net_cents: affiliate_cents,
        holding_amount_currency: Currency::USD, holding_amount_net_cents: affiliate_cents
      )

      balance = balance_transaction.balance
      expect(balance).to have_attributes(currency: Currency::USD, holding_currency: Currency::USD)
      expect(balance.holding_amount_cents).to eq(balance.amount_cents)
      expect(PaypalPayoutProcessor.is_balance_payable(balance)).to be(true)
    end

    it "leaves the seller's own leg in the connected account's currency" do
      purchase.increment_sellers_balance!
      balance_transaction = purchase.balance_transactions.find_by(user: seller)

      expect(balance_transaction.merchant_account).to eq(seller_account)
      expect(balance_transaction.holding_amount_currency).to eq(Currency::EUR)
    end

    it "books the refund leg in USD, against the same balance it debits" do
      purchase.increment_sellers_balance!
      refund = create(:refund, purchase:)

      purchase.process_refund_or_chargeback_for_affiliate_credit_balance(eur_flow_of_funds(-1), refund:, refund_cents: affiliate_cents)

      balance_transaction = refund.balance_transactions.find_by(user: affiliate_user)
      expect(balance_transaction).to have_attributes(
        issued_amount_currency: Currency::USD, issued_amount_net_cents: -affiliate_cents,
        holding_amount_currency: Currency::USD, holding_amount_net_cents: -affiliate_cents
      )
      expect(balance_transaction.balance).to eq(affiliate_success_transaction.balance)
      expect(balance_transaction.balance.reload.amount_cents).to eq(0)
    end

    def book_affiliate_chargeback!
      dispute = create(:dispute_formalized, purchase:)
      purchase.process_refund_or_chargeback_for_affiliate_credit_balance(eur_flow_of_funds(-1), dispute:, refund_cents: affiliate_cents)
      purchase.reload
      dispute.balance_transactions.find_by!(user: affiliate_user)
    end

    def win_affiliate_dispute!
      purchase.create_credit_for_dispute_won_for_affiliate!(eur_flow_of_funds(1), amount_cents: affiliate_cents)
      Credit.last.balance_transaction
    end

    it "offsets the chargeback debit with a USD re-credit on the same balance" do
      purchase.increment_sellers_balance!
      debit = book_affiliate_chargeback!

      recredit = win_affiliate_dispute!

      expect(recredit.user).to eq(affiliate_user)
      expect(recredit).to have_attributes(
        issued_amount_currency: Currency::USD, issued_amount_net_cents: affiliate_cents,
        holding_amount_currency: Currency::USD, holding_amount_net_cents: affiliate_cents
      )
      expect(recredit.balance).to eq(debit.balance)
      expect(recredit.balance.reload).to have_attributes(amount_cents: affiliate_cents, holding_amount_cents: affiliate_cents)
    end

    # Legacy reversals must offset the recorded credit without relabelling its balance.
    describe "reversing a credit still on a legacy foreign-labelled balance" do
      def legacy_affiliate_balance!(state: "unpaid")
        purchase.increment_sellers_balance!
        balance_transaction = affiliate_success_transaction
        balance_transaction.update_columns(issued_amount_currency: Currency::EUR, holding_amount_currency: Currency::EUR)
        balance = balance_transaction.balance
        balance.update_columns(currency: Currency::EUR, holding_currency: Currency::EUR, state:)
        purchase.reload
        balance
      end

      def refund_affiliate!
        refund = create(:refund, purchase:)
        purchase.process_refund_or_chargeback_for_affiliate_credit_balance(eur_flow_of_funds(-1), refund:, refund_cents: affiliate_cents)
        refund.balance_transactions.find_by!(user: affiliate_user)
      end

      it "books the refund under the credit's own label so it nets on that balance" do
        legacy_balance = legacy_affiliate_balance!

        balance_transaction = refund_affiliate!

        expect(balance_transaction).to have_attributes(
          issued_amount_currency: Currency::EUR, issued_amount_net_cents: -affiliate_cents,
          holding_amount_currency: Currency::EUR, holding_amount_net_cents: -affiliate_cents
        )
        expect(balance_transaction.balance).to eq(legacy_balance)
        expect(legacy_balance.reload).to have_attributes(amount_cents: 0, holding_amount_cents: 0)
        expect(Balance.where(user: affiliate_user).count).to eq(1)
      end

      # Every Stripe payout claims foreign Gumroad-held rows as processing, fails on currency_mismatch
      # and hands them back as unpaid, so a refund can land mid-attempt.
      it "keeps the credit's label while a failing payout holds its balance, so the pair still nets" do
        legacy_balance = legacy_affiliate_balance!(state: "processing")

        balance_transaction = refund_affiliate!
        legacy_balance.reload.mark_unpaid!

        expect(balance_transaction).to have_attributes(issued_amount_currency: Currency::EUR, holding_amount_currency: Currency::EUR)
        affiliate_balances = Balance.where(user: affiliate_user)
        expect(affiliate_balances.pluck(:holding_currency).uniq).to eq([Currency::EUR])
        expect(affiliate_balances.unpaid.sum(:holding_amount_cents)).to eq(0)
      end

      it "reads the credit's current label, not an association loaded before a relabel" do
        legacy_balance = legacy_affiliate_balance!
        expect(purchase.affiliate_credit.affiliate_credit_success_balance.holding_currency).to eq(Currency::EUR)
        Balance.where(id: legacy_balance.id).update_all(currency: Currency::USD, holding_currency: Currency::USD)

        balance_transaction = refund_affiliate!

        expect(balance_transaction).to have_attributes(issued_amount_currency: Currency::USD, holding_amount_currency: Currency::USD)
        expect(balance_transaction.balance).to eq(legacy_balance)
      end

      it "nets a legacy chargeback debit and its re-credit on the credit's balance" do
        legacy_balance = legacy_affiliate_balance!
        debit = book_affiliate_chargeback!

        recredit = win_affiliate_dispute!

        expect([debit, recredit].map(&:holding_amount_currency)).to eq([Currency::EUR, Currency::EUR])
        expect(recredit.balance).to eq(legacy_balance)
        expect(legacy_balance.reload.amount_cents).to eq(affiliate_cents)
      end

      it "re-credits onto the recorded chargeback debit when the original credit has been paid" do
        legacy_affiliate_balance!(state: "paid")
        debit = book_affiliate_chargeback!
        expect(debit.balance).to be_unpaid

        recredit = win_affiliate_dispute!

        expect(recredit.holding_amount_currency).to eq(debit.holding_amount_currency)
        expect(recredit.balance).to eq(debit.balance)
        expect(debit.balance.reload).to have_attributes(amount_cents: 0, holding_amount_cents: 0)
      end

      it "re-credits under the chargeback debit's label, not the credit's, when they differ" do
        legacy_affiliate_balance!
        dispute = create(:dispute_formalized, purchase:)
        usd = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -affiliate_cents, net_cents: -affiliate_cents)
        debit = BalanceTransaction.create!(user: affiliate_user, merchant_account: affiliate_success_transaction.merchant_account,
                                           dispute:, issued_amount: usd, holding_amount: usd)
        purchase.affiliate_credit.update!(affiliate_credit_chargeback_balance: debit.balance)
        purchase.reload

        recredit = win_affiliate_dispute!

        expect(recredit).to have_attributes(issued_amount_currency: Currency::USD, holding_amount_currency: Currency::USD)
        expect(recredit.balance).to eq(debit.balance)
        expect(debit.balance.reload.amount_cents).to eq(0)
      end
    end
  end
end
