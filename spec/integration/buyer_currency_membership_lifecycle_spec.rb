# frozen_string_literal: true

require "spec_helper"

# INTEGRATION coverage for the two halves of gumroad-private#1322. These exist because the unit
# specs could not see the defect that mattered: an earlier version of this feature stored the
# fixing from Charge::PresentmentOrchestrator (where purchase.subscription is still nil) and read
# it back from Charge::CreateService (which renewals never enter), so both halves were dead code
# while every unit example stayed green. Each example here drives a REAL entry point.
describe "Buyer-currency memberships, signup through renewal", :vcr do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:product) { create(:membership_product, user: seller, price_cents: 1000) }

  # For the cases that are NOT about write ordering, invoke the writer through a real service
  # instance rather than rebuilding the whole success path.
  def subject_service(purchase)
    Purchase::MarkSuccessfulService.new(purchase)
  end

  before do
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
    merchant_account
  end

  describe "the signup fixes the amount" do
    # Drives Purchase::MarkSuccessfulService — the real success path — rather than calling the
    # writer directly, because the whole point is WHEN the subscription exists relative to the
    # write. A direct call would pass against the broken ordering too.
    it "stores a fixing once the subscription exists, reading the price off the purchase presentment" do
      # A membership signup mid-charge: the Subscription does not exist yet (that is the whole
      # point — the earlier broken version wrote the fixing before this moment), but the purchase
      # carries the recurring price the payment option is built from.
      purchase = build(:membership_purchase, link: product, seller:, merchant_account:, price_cents: 1000,
                                             purchase_state: "in_progress", subscription: nil)
      purchase.price = product.prices.alive.first || product.prices.first
      purchase.variant_attributes = []
      purchase.save!(validate: false)
      charge = create(:charge, seller:, merchant_account:)
      charge_presentment = create(:charge_presentment, charge:, presentment_currency: "eur", fx_rate: 0.9)
      create(:purchase_presentment, purchase:, charge_presentment:,
                                    presentment_currency: "eur", presentment_price_cents: 899,
                                    presentment_gumroad_tax_cents: 0, presentment_total_cents: 899)

      expect { Purchase::MarkSuccessfulService.new(purchase).perform }
        .to change(LaterChargePresentment, :count).by(1)

      fixing = purchase.reload.subscription.current_later_charge_presentment
      expect(fixing.presentment_currency).to eq("eur")
      expect(fixing.presentment_price_cents).to eq(899)
      expect(fixing.canonical_price_cents).to eq(1000)
      # Stored as the reciprocal of the quote's fx_rate: 0.9 USD per EUR means 1/0.9 EUR per USD.
      expect(fixing.signup_currency_units_per_usd).to be_within(BigDecimal("0.000001")).of(BigDecimal(1) / BigDecimal("0.9"))
    end

    it "stores the product rate for a direct-listed INR signup that has no FX quote" do
      inr_product = create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 83_000)
      purchase = create(:membership_purchase, link: inr_product, seller:, merchant_account:, price_cents: 1000,
                                              rate_converted_to_usd: BigDecimal("83"))
      charge_presentment = create(
        :charge_presentment,
        charge: create(:charge, seller:, merchant_account:),
        presentment_currency: Currency::INR,
        stripe_fx_quote_id: nil,
        stripe_fx_quote_expires_at: nil,
        fx_rate: nil
      )
      create(:purchase_presentment, purchase:, charge_presentment:,
                                    presentment_currency: Currency::INR, presentment_price_cents: 83_000,
                                    presentment_gumroad_tax_cents: 0, presentment_total_cents: 83_000)

      expect { subject_service(purchase).send(:fix_later_charge_presentment) }
        .to change(LaterChargePresentment, :count).by(1)

      fixing = purchase.reload.subscription.current_later_charge_presentment
      expect(fixing.presentment_currency).to eq(Currency::INR)
      expect(fixing.signup_currency_units_per_usd).to eq(BigDecimal("83"))
    end

    it "writes nothing when the signup charged canonical dollars" do
      # A normal membership signup with no purchase_presentment: nothing to fix, so later charges
      # keep billing canonical dollars exactly as they did before this feature.
      purchase = create(:membership_purchase, link: product, seller:, merchant_account:, price_cents: 1000)

      expect { subject_service(purchase).send(:fix_later_charge_presentment) }
        .not_to change(LaterChargePresentment, :count)
    end

    it "refuses to fulfill a UPI signup without a durable INR fixing" do
      upi_card = CreditCard.create!(
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        payment_method_type: "upi",
        stripe_customer_id: "cus_upi_missing_fixing",
        processor_payment_method_id: "pm_upi_missing_fixing",
        stripe_fingerprint: "pm_upi_missing_fixing",
        visual: "UPI",
        card_type: CardType::UPI,
        card_country: Compliance::Countries::IND.alpha2,
        recurring_authorization_verified_at: Time.current,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 100_000
      )
      purchase = create(:membership_purchase, link: product, seller:, price_cents: 1000,
                                              purchase_state: "in_progress", credit_card: upi_card)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(RuntimeError), purchase_id: purchase.id)

      expect { subject_service(purchase).perform }
        .to raise_error(RuntimeError, /without a durable INR renewal fixing/)
      expect(purchase.reload).to be_in_progress
    end

    it "writes nothing for a gift, whose subscription belongs to someone who never saw the price" do
      purchase = create(:membership_purchase, link: product, seller:, merchant_account:, price_cents: 1000)
      charge = create(:charge, seller:, merchant_account:)
      charge_presentment = create(:charge_presentment, charge:, presentment_currency: "eur", fx_rate: 0.9)
      create(:purchase_presentment, purchase:, charge_presentment:,
                                    presentment_currency: "eur", presentment_price_cents: 899,
                                    presentment_gumroad_tax_cents: 0, presentment_total_cents: 899)
      allow(purchase).to receive(:is_gift_sender_purchase?).and_return(true)

      expect { subject_service(purchase).send(:fix_later_charge_presentment) }
        .not_to change(LaterChargePresentment, :count)
    end
  end

  describe "the renewal bills the fixed amount" do
    let(:subscription) { create(:subscription, link: product, user: create(:user)) }
    let!(:original) do
      create(:membership_purchase, link: product, seller:, subscription:, merchant_account:,
                                   is_original_subscription_purchase: true, price_cents: 1000)
    end
    let!(:fixing) do
      create(:later_charge_presentment, owner: subscription, presentment_currency: "eur",
                                        presentment_price_cents: 899, canonical_price_cents: 1000,
                                        signup_currency_units_per_usd: BigDecimal("1.111111111111111"),
                                        effective_from: 30.days.ago)
    end
    let(:renewal) do
      create(:membership_purchase,
             link: product,
             seller:,
             subscription:,
             merchant_account:,
             price_cents: 1000,
             is_original_subscription_purchase: false,
             purchase_state: "in_progress",
             succeeded_at: nil,
             stripe_transaction_id: nil,
             charge_processor_id: StripeChargeProcessor.charge_processor_id,
             flow_of_funds: nil)
    end

    before do
      allow(StripeFxQuote).to receive(:create)
        .and_return(double(id: "fxq_renewal", fx_rate: 0.8, expires_at: 1.day.from_now))
      allow(Checkout::BuyerCurrencyEligibility).to receive(:usd_settling_merchant_account?).and_return(true)
      allow(StripeChargeProcessor).to receive(:charge_minor_units_compatible?).and_return(true)
      allow(renewal).to receive(:merchant_account).and_return(merchant_account)
      allow(renewal).to receive(:charge_processor_id).and_return(StripeChargeProcessor.charge_processor_id)
    end

    def processor_charge(flow_of_funds:)
      BaseProcessorCharge.new.tap do |charge|
        charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
        charge.id = "ch_renewal"
        charge.status = "succeeded"
        charge.refunded = false
        charge.fee = 59
        charge.fee_currency = Currency::USD
        charge.card_fingerprint = "card_fp"
        charge.card_expiry_month = 12
        charge.card_expiry_year = 2030
        charge.zip_check_result = "pass"
        charge.flow_of_funds = flow_of_funds
      end
    end

    def charge_intent(processor_charge)
      ChargeIntent.new.tap do |intent|
        intent.id = "pi_renewal"
        intent.charge = processor_charge
      end
    end

    # THE test whose absence hid the dead renewal read. Asserts on the args handed to the
    # processor from Purchase#create_charge_intent, the site renewals really use.
    it "hands the stored EUR amount to the processor instead of canonical dollars" do
      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
        expect(kwargs[:processor_currency]).to eq("eur")
        expect(kwargs[:processor_amount_cents]).to eq(899)
        expect(kwargs[:stripe_fx_quote_id]).to eq("fxq_renewal")
        double(id: "pi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
      end

      renewal.send(:create_charge_intent, double(get_chargeable_for: double))
    end

    it "defers a settled renewal until Stripe exposes its flow of funds" do
      renewal.chargeable = double(get_chargeable_for: double, requires_mandate?: false, fingerprint: "card_fp")
      allow(renewal).to receive(:process!) { |off_session: true| renewal.charge!(off_session:) }
      create(
        :purchase_presentment,
        purchase: renewal,
        charge_presentment: nil,
        presentment_currency: "eur",
        presentment_price_cents: 899,
        presentment_gumroad_tax_cents: 0,
        presentment_total_cents: 899
      )
      renewal.association(:purchase_presentment).reset
      allow(renewal).to receive(:create_charge_intent).and_return(charge_intent(processor_charge(flow_of_funds: nil)))

      subscription.process_purchase!(renewal)

      expect(renewal.reload).to be_in_progress
      expect(renewal.purchase_presentment).to be_present
      expect(FinalizeBuyerPresentmentPurchaseJob.jobs.last["args"]).to eq([renewal.id])

      presentment = renewal.purchase_presentment
      settled_flow = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: presentment.presentment_currency, cents: presentment.presentment_total_cents),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: renewal.total_transaction_cents),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: renewal.total_transaction_amount_for_gumroad_cents),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: renewal.total_transaction_cents),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: renewal.payment_cents)
      )
      allow(ChargeProcessor).to receive(:get_or_search_charge).and_return(processor_charge(flow_of_funds: settled_flow))
      FinalizeBuyerPresentmentPurchaseJob.jobs.clear

      FinalizeBuyerPresentmentPurchaseJob.new.perform(renewal.id)

      expect(renewal.reload).to be_successful
      expect(FinalizeBuyerPresentmentPurchaseJob.jobs.size).to eq(0)
    end

    it "falls back to canonical dollars when the plan moved since the fixing" do
      # A limited-duration discount expiring, an upgrade, a quantity change: the canonical price
      # no longer matches what the fixing was agreed against, so the stored amount is stale.
      #
      # total_transaction_cents has to move with price_cents: the anchor reads it (through
      # LaterChargePresentment.canonical_price_cents_for) and nothing recomputes it on update!,
      # so setting price_cents alone leaves the anchor matching and the gate never trips.
      renewal.update!(price_cents: 1500, total_transaction_cents: 1500)

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
        expect(kwargs).not_to include(:processor_currency)
        expect(kwargs).not_to include(:processor_amount_cents)
        double(id: "pi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
      end

      renewal.send(:create_charge_intent, double(get_chargeable_for: double))
    end

    it "falls back to canonical dollars when the buyer is present at the charge" do
      # An upgrade or a restart at checkout charges on-session through
      # Subscription::UpdaterService, with a non-original purchase and a fixing in place. The
      # buyer is looking at a total on their screen, so the amount fixed months ago must not be
      # billed instead. A restart at the unchanged plan price is the case the staleness anchor
      # cannot catch, since the anchor still matches.
      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
        expect(kwargs).not_to include(:processor_currency)
        expect(kwargs).not_to include(:processor_amount_cents)
        double(id: "pi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
      end

      renewal.send(:create_charge_intent, double(get_chargeable_for: double), off_session: false)
    end

    it "falls back to canonical dollars for a subscription with no fixing" do
      fixing.destroy!

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
        expect(kwargs).not_to include(:processor_currency)
        double(id: "pi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
      end

      renewal.send(:create_charge_intent, double(get_chargeable_for: double))
    end

    it "keeps billing a fixed member after the ramp flag is pulled" do
      # The never-orphan invariant: pulling the ramp stops NEW memberships entering the lane, it
      # must not switch an existing member's currency mid-subscription.
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
        expect(kwargs[:processor_currency]).to eq("eur")
        expect(kwargs[:processor_amount_cents]).to eq(899)
        double(id: "pi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
      end

      renewal.send(:create_charge_intent, double(get_chargeable_for: double))
    end

    context "with a saved UPI Autopay instrument" do
      let(:product) do
        create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 83_000)
      end

      let!(:upi_fixing) do
        create(
          :later_charge_presentment,
          owner: subscription,
          presentment_currency: Currency::INR,
          presentment_price_cents: 899,
          canonical_price_cents: 1000,
          signup_currency_units_per_usd: BigDecimal("1.111111111111111"),
          effective_from: 1.day.ago
        )
      end

      let!(:upi_card) do
        CreditCard.create!(
          charge_processor_id: StripeChargeProcessor.charge_processor_id,
          payment_method_type: "upi",
          stripe_customer_id: "cus_upi",
          processor_payment_method_id: "pm_upi",
          stripe_fingerprint: "pm_upi",
          visual: "UPI",
          card_type: CardType::UPI,
          card_country: "IN",
          recurring_authorization_verified_at: Time.current,
          recurring_authorization_currency: Currency::INR,
          recurring_authorization_max_amount_cents: 100_000,
          json_data: { stripe_payment_intent_id: "pi_upi_signup" }
        )
      end

      before do
        Feature.activate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
        fixing.destroy!
        subscription.update!(credit_card: upi_card)
        renewal.update!(credit_card: upi_card)
      end

      it "defers the renewal without calling Stripe when servicing is disabled" do
        Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
        allow(renewal).to receive(:process!) do
          renewal.send(:create_charge_intent, double(get_chargeable_for: double))
        end
        expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)
        expect(ErrorNotifier).to receive(:notify).with(
          "UPI Autopay renewal deferred before Stripe submit",
          reason: "servicing flag inactive",
          purchase_id: renewal.id
        )
        expect(subscription).to receive(:schedule_charge).with(be_within(2.seconds).of(1.hour.from_now))
        expect(CustomerLowPriorityMailer).not_to receive(:subscription_card_declined)

        subscription.process_purchase!(renewal)

        expect(renewal.error_code).to eq(PurchaseErrorCode::STRIPE_UNAVAILABLE)
        expect(renewal).to be_has_payment_network_error
      end

      it "hands INR to the processor without consulting the acquisition flags" do
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)

        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
          expect(kwargs[:processor_currency]).to eq(Currency::INR)
          expect(kwargs[:processor_amount_cents]).to eq(899)
          double(id: "pi_upi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
        end

        renewal.send(:create_charge_intent, double(get_chargeable_for: double))
        expect(upi_card.reload.stripe_payment_intent_id).to eq("pi_upi_signup")
      end

      it "requests a payment-method update rather than calling Stripe in USD when the fixing is missing" do
        upi_fixing.destroy!
        expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)
        expect(ErrorNotifier).to receive(:notify).with(
          "Required-currency renewal rejected before processor submit",
          reason: :no_stored_presentment,
          required_currency: Currency::INR,
          purchase_id: renewal.id,
          charge_id: nil
        )

        result = renewal.send(:create_charge_intent, double(get_chargeable_for: double))

        expect(result).to be_nil
        expect(renewal.stripe_error_code).to eq(PurchaseErrorCode::UPI_RECURRING_AUTHORIZATION_REQUIRED)
      end

      it "schedules a retry when the INR quote is temporarily unavailable" do
        allow(StripeFxQuote).to receive(:create).and_return(nil)
        allow(renewal).to receive(:process!) do
          renewal.send(:create_charge_intent, double(get_chargeable_for: double))
        end
        expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)
        expect(subscription).to receive(:schedule_charge).with(be_within(2.seconds).of(1.hour.from_now))
        expect(CustomerLowPriorityMailer).not_to receive(:subscription_card_declined)

        subscription.process_purchase!(renewal)

        expect(renewal.error_code).to eq(PurchaseErrorCode::STRIPE_UNAVAILABLE)
        expect(renewal).to be_has_payment_network_error
      end

      it "re-fixes a direct-INR renewal after its limited discount expires" do
        renewal.update!(
          price_cents: 1500,
          total_transaction_cents: 1500,
          displayed_price_currency_type: Currency::INR,
          displayed_price_cents: 124_500,
          rate_converted_to_usd: BigDecimal("83")
        )

        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*_args, **kwargs|
          expect(kwargs[:processor_currency]).to eq(Currency::INR)
          expect(kwargs[:processor_amount_cents]).to eq(124_500)
          double(id: "pi_upi_renewal", succeeded?: true, requires_action?: false, get_charge: nil)
        end

        expect { renewal.send(:create_charge_intent, double(get_chargeable_for: double)) }
          .to change(LaterChargePresentment, :count).by(1)

        expect(subscription.current_later_charge_presentment).to have_attributes(
          presentment_price_cents: 124_500,
          canonical_price_cents: 1500
        )
      end
    end
  end
end
