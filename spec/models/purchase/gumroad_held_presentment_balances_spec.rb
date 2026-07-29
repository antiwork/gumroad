# frozen_string_literal: true

require "spec_helper"

# End-to-end coverage of what the ledger records for a buyer-currency (presentment) purchase
# whose funds Gumroad holds itself, driven through the real booking methods
# (`increment_sellers_balance!` and `decrement_balance_for_refund_or_chargeback!`) rather than by
# calling `BalanceTransaction::Amount` directly.
#
# The unit specs in spec/models/balance_transaction_spec.rb pin the branch that picks the currency.
# These specs pin the thing that actually matters to a seller: that a real EUR purchase books a
# balance the payout processors will accept. See gumroad-private#1471 — the whole incident was a
# correct-looking `Amount` object flowing into a balance nobody could be paid from.
#
# ## What "Gumroad-held" means here, and why the holding fields are USD
#
# For funds Gumroad holds, `holding_*` is Gumroad's canonical record of what it owes the seller — a
# liability, always denominated in USD, because USD is the currency every Gumroad-held payout is
# computed and wired in. It is deliberately not a record of which currency Stripe is physically
# sitting on: the platform account really does carry foreign-currency balances (a EUR charge can
# settle and stay in EUR), but that is an account-level treasury position spanning every seller and
# nothing about paying one seller follows from it.
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

  # A EUR-presentment purchase booked against the Gumroad-held account.
  #
  # `flow_of_funds` is assigned rather than obtained from a live charge because the flow of funds is
  # exactly the input under test: production hands this method a flow whose settled amount is in the
  # buyer's currency, and that is what used to leak into the holding fields. Building it here lets
  # the spec state the shape it is about instead of depending on what a cassette happens to contain.
  #
  # `settled_cents` defaults to the EUR amount with no `merchant_account_*` leg, which is the shape
  # a Gumroad-held charge produces — there is no destination payment, so those are nil.
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
    # The quote-less shape. Forced-currency local methods (iDEAL, Bancontact) and any product
    # already listed in the buyer's currency take no FX quote at all — Stripe does not convert, so
    # the funds settle and stay in EUR. 19 of the affected production rows arrived this way, and a
    # fix keyed on the quote rather than on who holds the funds would have missed every one of them.
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
      # The canonical issued amount survives the missing quote — this is why gating the fix on the
      # quote would not have worked. It is non-nil on the presence of a presentment row alone.
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

      # And explicitly not the buyer's currency, which is what the incident recorded.
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

      # The assertion is that the currency guard did NOT fire, not that the whole method succeeded:
      # once past the guard it goes on to make a real Stripe internal transfer, which is a network
      # call well downstream of the currency decision under test. A `currency_mismatch` failure is
      # what the incident produced and is what must be absent here.
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

      # The label is what keys a balance, so a EUR negative leg would open a *second*, EUR-labelled
      # balance for this seller — which is how one refund could re-break an already-repaired seller.
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

  # The quote-backed lane, which the incident did not affect — Stripe converts at settlement, so the
  # settled currency was already USD and the old code produced a USD label by accident rather than
  # on purpose. What this change does move is the holding GROSS: it was Stripe's settled figure
  # (post-conversion, net of Stripe's FX spread) and is now the canonical issued amount Gumroad's
  # books recorded. Both are USD, so nothing here was ever unpayable; the point of this spec is that
  # the change to gross is deliberate and pinned rather than incidental.
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
      # Explicitly not Stripe's settled amount, which is what the old branch wrote here.
      expect(balance_transaction.holding_amount_gross_cents).to_not eq(96_00)
      # The net — the only holding field that accumulates into the balance, and therefore the only
      # one that could move money — is unchanged by this.
      expect(balance_transaction.holding_amount_net_cents).to eq(purchase.payment_cents)
      expect(purchase.purchase_success_balance.holding_amount_cents).to eq(purchase.purchase_success_balance.amount_cents)
    end
  end
end
