# frozen_string_literal: true

require "spec_helper"

describe Purchase::FinalizeConfirmedChargeService do
  def charge_intent_double(succeeded: true, processing: false, card_country: "US",
                           card_last4: "4242", card_number_length: 16, card_type: "visa")
    processor_charge = double("StripeCharge", card_last4:, card_number_length:, card_type:, card_country:)
    instance_double(StripeChargeIntent, succeeded?: succeeded, processing?: processing, charge: processor_charge)
  end

  describe "#perform" do
    context "when the intent succeeded" do
      let(:purchase) { create(:purchase_in_progress, card_country: "US", card_country_source: "stripe") }

      before do
        # Isolate the card-presentation logic from the heavier fulfillment machinery.
        allow(purchase).to receive(:save_charge_data)
        allow_any_instance_of(described_class).to receive(:handle_purchase_success)
      end

      it "derives card_visual and card_type from the confirmed charge" do
        described_class.new(purchase:, charge_intent: charge_intent_double).perform

        expect(purchase.card_visual).to eq("**** **** **** 4242")
        expect(purchase.card_type).to eq("visa")
      end

      it "keeps the previewed card_country when the confirmed charge has none" do
        # Regression for 626bacf95: a null country from the confirmed charge must not clobber the
        # country resolved from the ConfirmationToken preview at prepare time.
        result = described_class.new(purchase:, charge_intent: charge_intent_double(card_country: nil)).perform

        expect(result).to be_nil
        expect(purchase.card_country).to eq("US")
        expect(purchase.card_country_source).to eq("stripe")
      end

      it "refreshes card_country when the confirmed charge carries one" do
        described_class.new(purchase:, charge_intent: charge_intent_double(card_country: "CA")).perform

        expect(purchase.card_country).to eq("CA")
      end

      it "returns the buyer-facing error message when saving charge data fails" do
        allow(purchase).to receive(:save_charge_data) { purchase.errors.add(:base, "Something went wrong.") }

        result = described_class.new(purchase:, charge_intent: charge_intent_double).perform

        expect(result).to eq("Something went wrong.")
        expect(purchase.reload).to be_failed
      end
    end

    context "when a UPI membership signup succeeded" do
      let(:seller) { create(:user) }
      let(:product) do
        create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 100_000)
      end
      let(:merchant_account) do
        MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
          create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                    charge_processor_merchant_id: nil)
      end
      let(:purchase) do
        build(:membership_purchase, link: product, seller:, purchase_state: "in_progress",
                                    merchant_account:, credit_card: nil, subscription: nil,
                                    price_cents: 1205, total_transaction_cents: 1205,
                                    displayed_price_currency_type: Currency::INR,
                                    displayed_price_cents: 100_000,
                                    rate_converted_to_usd: BigDecimal("83")).tap do |purchase|
          purchase.price = product.prices.alive.first || product.prices.first
          purchase.variant_attributes = []
          purchase.save!(validate: false)
        end
      end
      let(:processor_charge) do
        BaseProcessorCharge.new.tap do |charge|
          charge.id = "ch_upi_signup"
          charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
          charge.payment_method_type = "upi"
          charge.card_instance_id = "pm_upi_signup"
          charge.card_fingerprint = "pm_upi_signup"
          charge.card_type = CardType::UPI
        end
      end
      let(:payment_intent) do
        Stripe::PaymentIntent.construct_from(
          id: "pi_upi_signup",
          customer: "cus_upi_signup",
          payment_method: "pm_upi_signup",
          status: StripeIntentStatus::SUCCESS,
          setup_future_usage: "off_session",
          currency: Currency::INR,
          metadata: {
            StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY => "100000"
          }
        )
      end
      let(:charge_intent) do
        instance_double(
          StripeChargeIntent,
          succeeded?: true,
          processing?: false,
          charge: processor_charge,
          payment_intent:
        )
      end

      before do
        allow(purchase).to receive(:save_charge_data)
      end

      it "saves the reusable authorization before subscription fulfillment" do
        allow_any_instance_of(described_class).to receive(:handle_purchase_success)

        result = described_class.new(purchase:, charge_intent:).perform

        expect(result).to be_nil
        expect(purchase.reload.credit_card).to be_upi
        expect(purchase.credit_card).to have_attributes(
          stripe_customer_id: "cus_upi_signup",
          processor_payment_method_id: "pm_upi_signup",
          recurring_authorization_currency: Currency::INR,
          recurring_authorization_max_amount_cents: 100_000
        )
      end

      it "fulfills the captured signup with its subscription, reusable method, and INR fixing" do
        create(
          :purchase_presentment,
          purchase:,
          charge_presentment: nil,
          presentment_currency: Currency::INR,
          presentment_price_cents: 100_000,
          presentment_tip_cents: 0,
          presentment_seller_tax_cents: 0,
          presentment_gumroad_tax_cents: 0,
          presentment_shipping_cents: 0,
          presentment_total_cents: 100_000,
          presentment_gumroad_amount_cents: 10_000
        )

        result = described_class.new(purchase:, charge_intent:).perform

        expect(result).to be_nil
        expect(purchase.reload).to be_successful
        expect(purchase.credit_card).to be_recurring_upi
        expect(purchase.subscription).to be_present
        expect(purchase.subscription.credit_card).to eq(purchase.credit_card)
        expect(purchase.subscription.current_later_charge_presentment).to have_attributes(
          presentment_currency: Currency::INR,
          presentment_price_cents: 100_000,
          canonical_price_cents: 1205
        )
      end

      it "keeps a captured payment recoverable when no INR fixing can be stored" do
        expect(ErrorNotifier).to receive(:notify).with(instance_of(RuntimeError), purchase_id: purchase.id).ordered
        expect(ErrorNotifier).to receive(:notify).with(
          instance_of(RuntimeError),
          context: {
            purchase_id: purchase.id,
            payment_intent_id: payment_intent.id,
          }
        ).ordered

        expect do
          expect(described_class.new(purchase:, charge_intent:).perform).to eq(:pending)
        end.to not_change(CreditCard, :count)
          .and not_change(Subscription, :count)

        expect(purchase.reload).to be_in_progress
        expect(purchase.stripe_status).to eq(StripeIntentStatus::SUCCESS)
        expect(purchase.credit_card).to be_nil
        expect(purchase.subscription).to be_nil
      end
    end

    context "when the intent is still processing" do
      let(:purchase) { create(:purchase_in_progress) }

      it "marks the purchase pending without fulfilling" do
        result = described_class.new(purchase:, charge_intent: charge_intent_double(succeeded: false, processing: true)).perform

        expect(result).to eq(:pending)
        expect(purchase.reload.stripe_status).to eq(StripeIntentStatus::PROCESSING)
        expect(purchase).to be_in_progress
      end
    end

    context "when the intent is waiting on an asynchronous customer-initiated payment (Pix)" do
      let(:purchase) { create(:purchase_in_progress) }

      # Real StripeChargeIntent rather than a double: the pending-vs-failed routing hangs on how
      # the intent classifies its next action, so the classification must be exercised, not stubbed.
      def stripe_charge_intent(next_action_type:, payment_method_types:)
        payment_intent = Stripe::PaymentIntent.construct_from(
          id: "pi_next_action_test",
          status: StripeIntentStatus::REQUIRES_ACTION,
          next_action: { type: next_action_type, next_action_type.to_sym => { expires_at: 30.minutes.from_now.to_i } },
          payment_method_types:
        )
        StripeChargeIntent.new(payment_intent:)
      end

      it "keeps a Pix purchase in progress and reports pending — the buyer can still pay the QR key in their banking app" do
        charge_intent = stripe_charge_intent(next_action_type: "pix_display_qr_code", payment_method_types: ["pix"])

        result = described_class.new(purchase:, charge_intent:).perform

        expect(result).to eq(:pending)
        expect(purchase.reload.stripe_status).to eq(StripeIntentStatus::REQUIRES_ACTION)
        expect(purchase).to be_in_progress
      end

      # Cash App Pay's QR is scanned during checkout and resolves in the same session, so a confirm
      # that returns with the intent still in requires_action really does mean the buyer gave up —
      # it must keep failing, not start reporting pending because Pix taught us a new QR action.
      it "still fails a Cash App Pay purchase whose same-session QR was abandoned" do
        charge_intent = stripe_charge_intent(next_action_type: "cashapp_handle_redirect_or_display_qr_code", payment_method_types: ["cashapp"])

        result = described_class.new(purchase:, charge_intent:).perform

        expect(result).to eq("Sorry, something went wrong.")
        expect(purchase.reload).to be_failed
      end

      it "still fails a card purchase abandoned mid-SCA (use_stripe_sdk next action)" do
        payment_intent = Stripe::PaymentIntent.construct_from(
          id: "pi_sca_test",
          status: StripeIntentStatus::REQUIRES_ACTION,
          next_action: { type: StripeIntentStatus::ACTION_TYPE_USE_SDK },
          payment_method_types: ["card"]
        )
        charge_intent = StripeChargeIntent.new(payment_intent:)

        result = described_class.new(purchase:, charge_intent:).perform

        expect(result).to eq("Sorry, something went wrong.")
        expect(purchase.reload).to be_failed
      end
    end

    context "when the purchase is already successful" do
      let(:purchase) { create(:purchase_in_progress).tap { _1.update_column(:purchase_state, "successful") } }

      it "is a no-op so a second trigger does not re-fulfill" do
        expect(purchase).not_to receive(:save_charge_data)

        result = described_class.new(purchase:, charge_intent: charge_intent_double).perform

        expect(result).to be_nil
        expect(purchase.reload).to be_successful
      end
    end
  end
end
