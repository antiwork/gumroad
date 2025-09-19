# frozen_string_literal: true

require "spec_helper"

describe StripeChargeProcessor, :vcr do
  include CurrencyHelper
  include StripeMerchantAccountHelper
  include StripeChargesHelper

  describe ".charge_processor_id" do
    it "is 'stripe'" do
      expect(described_class.charge_processor_id).to eq "stripe"
    end
  end

  describe "#get_chargeable_for_params" do
    describe "with invalid params" do
      it "returns nil" do
        expect(subject.get_chargeable_for_params({}, nil)).to be(nil)
      end
    end

    context "with Stripe token" do
      describe "with only token" do
        let(:token) { CardParamsSpecHelper.success.to_stripejs_token }

        it "returns a chargeable token" do
          expect(StripeChargeableToken).to receive(:new).with(token, nil, product_permalink: nil).and_call_original

          expect(subject.get_chargeable_for_params({ stripe_token: token }, nil)).to be_a(StripeChargeableToken)
        end
      end

      describe "with token and zip code" do
        let(:token) { CardParamsSpecHelper.success.to_stripejs_token }

        it "returns a chargeable token" do
          expect(StripeChargeableToken).to receive(:new).with(token, nil, product_permalink: nil).and_call_original
          chargeable_token = subject.get_chargeable_for_params({ stripe_token: token, cc_zipcode: "12345" }, nil)
          expect(chargeable_token).to be_a(StripeChargeableToken)
          expect(chargeable_token.zip_code).to be(nil)
        end
      end

      describe "with token and zip code and zip code required" do
        let(:token) { CardParamsSpecHelper.success.with_zip_code("12345").to_stripejs_token }

        it "returns a chargeable token" do
          expect(StripeChargeableToken).to receive(:new).with(token, "12345", product_permalink: nil).and_call_original
          chargeable_token = subject.get_chargeable_for_params({ stripe_token: token, cc_zipcode: "12345", cc_zipcode_required: "true" }, nil)
          expect(chargeable_token).to be_a(StripeChargeableToken)
          expect(chargeable_token.zip_code).to eq("12345")
        end
      end
    end

    context "with Stripe payment method" do
      describe "with only a payment method" do
        let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }

        it "returns a chargeable payment method" do
          chargeable_payment_method = subject.get_chargeable_for_params({ stripe_payment_method_id: payment_method_id }, nil)

          expect(chargeable_payment_method).to be_a(StripeChargeablePaymentMethod)
          expect(chargeable_payment_method.payment_method_id).to eq(payment_method_id)
        end
      end

      describe "with a payment method" do
        let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }

        it "returns a chargeable payment method" do
          chargeable_payment_method = subject.get_chargeable_for_params({ stripe_payment_method_id: payment_method_id }, nil)

          expect(chargeable_payment_method).to be_a(StripeChargeablePaymentMethod)
        end
      end

      describe "with a payment method and a zip code and zip code not required" do
        let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }

        it "returns a chargeable payment method" do
          chargeable_payment_method = subject.get_chargeable_for_params({ stripe_payment_method_id: payment_method_id, cc_zipcode: "12345" }, nil)

          expect(chargeable_payment_method).to be_a(StripeChargeablePaymentMethod)
          expect(chargeable_payment_method.zip_code).to be(nil)
        end
      end

      describe "with a payment method and a zip code and zip code required" do
        let(:payment_method_id) { StripePaymentMethodHelper.success.with_zip_code("12345").to_stripejs_payment_method_id }

        it "returns a chargeable payment method" do
          chargeable_payment_method = subject.get_chargeable_for_params({ stripe_payment_method_id: payment_method_id, cc_zipcode: "12345", cc_zipcode_required: "true" }, nil)

          expect(chargeable_payment_method).to be_a(StripeChargeablePaymentMethod)
          expect(chargeable_payment_method.zip_code).to eq("12345")
        end
      end
    end
  end

  describe "#get_chargeable_for_data" do
    describe "with data" do
      it "returns a chargeable" do
        chargeable = subject.get_chargeable_for_data(
          "customer-id",
          "payment_method_id",
          "fingerprint",
          nil,
          nil,
          "4242",
          16,
          "**** **** **** 4242",
          1,
          2015,
          CardType::VISA,
          "US"
        )
        expect(chargeable.reusable_token!(nil)).to eq("customer-id")
        expect(chargeable.payment_method_id).to eq("payment_method_id")
        expect(chargeable.fingerprint).to eq("fingerprint")
        expect(chargeable.last4).to eq("4242")
        expect(chargeable.number_length).to eq(16)
        expect(chargeable.visual).to eq("**** **** **** 4242")
        expect(chargeable.expiry_month).to eq(1)
        expect(chargeable.expiry_year).to eq(2015)
        expect(chargeable.card_type).to eq(CardType::VISA)
        expect(chargeable.country).to eq("US")
        expect(chargeable.zip_code).to be(nil)
      end
    end

    describe "with data including zip code" do
      it "returns a chargeable with zip code" do
        chargeable = subject.get_chargeable_for_data(
          "customer-id",
          "payment_method_id",
          "fingerprint",
          nil,
          nil,
          "4242",
          16,
          "**** **** **** 4242",
          1,
          2015,
          CardType::VISA,
          "US",
          "94107"
        )
        expect(chargeable.reusable_token!(nil)).to eq("customer-id")
        expect(chargeable.payment_method_id).to eq("payment_method_id")
        expect(chargeable.fingerprint).to eq("fingerprint")
        expect(chargeable.last4).to eq("4242")
        expect(chargeable.number_length).to eq(16)
        expect(chargeable.visual).to eq("**** **** **** 4242")
        expect(chargeable.expiry_month).to eq(1)
        expect(chargeable.expiry_year).to eq(2015)
        expect(chargeable.card_type).to eq(CardType::VISA)
        expect(chargeable.country).to eq("US")
        expect(chargeable.zip_code).to eq("94107")
      end
    end
  end

  describe "#get_charge" do
    describe "with an invalid charge id" do
      let(:charge_id) { "an-invalid-charge-id" }

      it "raises error" do
        expect { subject.get_charge(charge_id) }.to raise_error(ChargeProcessorInvalidRequestError)
      end
    end

    describe "when the charge processor is unavailable" do
      before do
        expect(Stripe::Charge).to receive(:retrieve).and_raise(Stripe::APIConnectionError)
      end

      it "raises error" do
        expect { subject.get_charge("a-charge-id") }.to raise_error(ChargeProcessorUnavailableError)
      end
    end

    describe "with a valid charge id" do
      let(:stripe_charge) do
        stripe_charge = create_stripe_charge(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                                             amount: 1_00,
                                             currency: "usd",
        )
        Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction])
      end

      let(:charge_id) { stripe_charge.id }

      let(:charge) { subject.get_charge(charge_id) }

      it "returns a charge object" do
        expect(charge).to be_a(BaseProcessorCharge)
      end

      it "has matching id" do
        expect(charge.id).to eq(stripe_charge.id)
      end

      it "has matching fingerprint" do
        expect(charge.card_fingerprint).to eq(stripe_charge.payment_method_details.card.fingerprint)
      end

      it "has matching fee" do
        expect(charge.fee).to eq(stripe_charge.balance_transaction.fee_details.first.amount)
      end

      it "has matching fee cents" do
        expect(charge.fee_currency).to eq(stripe_charge.balance_transaction.fee_details.first.currency)
      end
    end
  end

  describe "#search_charge" do
    it "returns a Stripe::Charge object with details of the charge attached to the given purchase" do
      allow_any_instance_of(Purchase).to receive(:id).and_return(115787) # Charge with no destination connect account

      charge = subject.search_charge(purchase: create(:purchase))

      expect(charge).to be_a(Stripe::Charge)
      expect(charge.id).to eq("ch_0IvAB29e1RjUNIyY1hyx6deT")
      expect(charge.status).to eq("succeeded")

      allow_any_instance_of(Purchase).to receive(:id).and_return(115780) # Charge with a destination connect account

      charge = subject.search_charge(purchase: create(:purchase))

      expect(charge).to be_a(Stripe::Charge)
      expect(charge.id).to eq("ch_0Iv6ZR9e1RjUNIyYVBMK1ueH")
      expect(charge.status).to eq("succeeded")

      # Charge where transfer_group does not match but metadata matches
      allow_any_instance_of(Purchase).to receive(:id).and_return(1234567890)
      allow_any_instance_of(Purchase).to receive(:external_id).and_return("6RNPNSondrJ8t9SqSjxTjw==")

      charge = subject.search_charge(purchase: create(:purchase, created_at: Time.zone.at(1621973384)))

      expect(charge).to be_a(Stripe::Charge)
      expect(charge.id).to eq("ch_0Iv6ZR9e1RjUNIyYVBMK1ueH")
      expect(charge.status).to eq("succeeded")
    end

    it "returns a Stripe::Charge object for the given Stripe Connect purchase" do
      merchant_account = create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM", currency: "usd")

      allow_any_instance_of(Purchase).to receive(:id).and_return(88) # Charge on a Stripe Connect account

      charge = subject.search_charge(purchase: create(:purchase, link: create(:product, user: merchant_account.user), merchant_account:))

      expect(charge).to be_a(Stripe::Charge)
      expect(charge.id).to eq("ch_3Mf0bBKQKir5qdfM1FZ0agOH")
      expect(charge.status).to eq("succeeded")
    end

    it "returns nil if no stripe charge is found for the given purchase" do
      allow_any_instance_of(Purchase).to receive(:id).and_return(1234567890)

      expect(subject.search_charge(purchase: create(:purchase, created_at: Time.zone.at(1621973384)))).to be(nil)
    end
  end

  describe "#fight_chargeback" do
    let(:disputed_purchase) do
      create(
        :disputed_purchase,
        full_name: "John Example",
        street_address: "123 Sample St",
        city: "San Francisco",
        state: "CA",
        country: "United States",
        zip_code: "12343",
        ip_state: "California",
        ip_country: "United States",
        credit_card_zipcode: "1234",
        link: create(:physical_product),
        url_redirect: create(:url_redirect)
      )
    end
    let(:purchase_product_url) do
      Rails.application.routes.url_helpers.purchase_product_url(
        disputed_purchase.external_id,
        host: DOMAIN,
        protocol: PROTOCOL,
        anchor: "refund-policy",
      )
    end

    let!(:shipment) do
      create(
        :shipment,
        carrier: "UPS",
        tracking_number: "123456",
        purchase: disputed_purchase,
        ship_state: "shipped",
        shipped_at: DateTime.parse("2023-02-10 14:55:32")
      )
    end

    before do
      dispute = create(:dispute_formalized, purchase: disputed_purchase)

      disputed_purchase.create_purchase_refund_policy!(
        title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30],
        max_refund_period_in_days: 30,
        fine_print: "This is the fine print."
      )

      disputed_purchase.events.create!(
        event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW,
        link_id: disputed_purchase.link_id,
        browser_guid: disputed_purchase.browser_guid,
        created_at: disputed_purchase.created_at - 1.second
      )

      sample_image = File.read(Rails.root.join("spec", "support", "fixtures", "test-small.jpg"))
      allow(DisputeEvidence::GenerateReceiptImageService).to(
        receive(:perform).with(disputed_purchase).and_return(sample_image)
      )

      allow(DisputeEvidence::GenerateRefundPolicyImageService).to(
        receive(:perform)
          .with(url: purchase_product_url, mobile_purchase: false, open_fine_print_modal: true, max_size_allowed: anything)
          .and_return(sample_image)
      )
      DisputeEvidence.create_from_dispute!(dispute)
    end

    let!(:stripe_charge) do
      create_stripe_charge(StripePaymentMethodHelper.success_charge_disputed.to_stripejs_payment_method_id,
                           amount: 10_00,
                           currency: "usd")
    end

    let(:charge_id) do
      stripe_charge.refresh
      while stripe_charge.dispute.nil?
        stripe_charge.refresh
      end
      stripe_charge.id
    end

    it "retrieves charge from stripe" do
      expect(Stripe::Charge).to receive(:retrieve).with(charge_id).and_call_original
      subject.fight_chargeback(charge_id, disputed_purchase.dispute.dispute_evidence)
    end

    it "calls update_dispute on the stripe charge with the evidence as a parameter" do
      stripe_charge.refresh
      dispute_evidence = disputed_purchase.dispute.dispute_evidence
      dispute_evidence.update!(
        reason_for_winning: "reason_for_winning text",
        cancellation_rebuttal: "cancellation_rebuttal text",
        refund_refusal_explanation: "refund_refusal_explanation text"
      )
      expect(Stripe::Charge).to receive(:retrieve).with(charge_id).and_call_original
      expected_uncategorized_text = [
        "The merchant should win the dispute because:\n#{dispute_evidence.reason_for_winning}",
        dispute_evidence.uncategorized_text
      ].join("\n\n")
      expect(Stripe::Dispute).to receive(:update).with(
        stripe_charge.dispute,
        evidence: hash_including({
                                   billing_address: dispute_evidence.billing_address,
                                   customer_email_address: dispute_evidence.customer_email,
                                   customer_name: dispute_evidence.customer_name,
                                   customer_purchase_ip: dispute_evidence.customer_purchase_ip,
                                   product_description: dispute_evidence.product_description,
                                   service_date: dispute_evidence.purchased_at.to_fs(:formatted_date_full_month),
                                   shipping_address: dispute_evidence.shipping_address,
                                   shipping_carrier: dispute_evidence.shipping_carrier,
                                   shipping_date: dispute_evidence.shipped_at&.to_fs(:formatted_date_full_month),
                                   shipping_tracking_number: dispute_evidence.shipping_tracking_number,
                                   uncategorized_text: expected_uncategorized_text,
                                   access_activity_log: dispute_evidence.access_activity_log,
                                   refund_policy_disclosure: dispute_evidence.refund_policy_disclosure,
                                   cancellation_rebuttal: dispute_evidence.cancellation_rebuttal,
                                   refund_refusal_explanation: dispute_evidence.refund_refusal_explanation
                                 })
      ).and_call_original
      subject.fight_chargeback(charge_id, disputed_purchase.dispute.dispute_evidence)
    end

    it "includes the receipt image's Stripe file id in the dispute evidence" do
      allow(Stripe::File).to receive(:create).and_return(double(id: "receipt_file"))
      stripe_charge.refresh
      expect(Stripe::Dispute).to receive(:update).with(
        stripe_charge.dispute,
        evidence: hash_including({ receipt: "receipt_file" })
      )

      subject.fight_chargeback(charge_id, disputed_purchase.dispute.dispute_evidence)
    end

    it "includes the customer communication file's Stripe file id in the dispute evidence" do
      dispute_evidence = disputed_purchase.dispute.dispute_evidence
      dispute_evidence.customer_communication_file.attach(fixture_file_upload("smilie.png"))

      allow(Stripe::File).to receive(:create).and_return(double(id: "customer_communication_file"))
      stripe_charge.refresh
      expect(Stripe::Dispute).to receive(:update).with(
        stripe_charge.dispute,
        evidence: hash_including({ customer_communication: "customer_communication_file" })
      )

      subject.fight_chargeback(charge_id, disputed_purchase.dispute.dispute_evidence)
    end

    context "when the associated product is not a membership" do
      it "includes the refund_policy's Stripe file id in the dispute evidence" do
        allow(Stripe::File).to receive(:create).and_return(double(id: "refund_policy_file"))
        stripe_charge.refresh
        expect(Stripe::Dispute).to receive(:update).with(
          stripe_charge.dispute,
          evidence: hash_including({ refund_policy: "refund_policy_file" })
        )

        subject.fight_chargeback(charge_id, disputed_purchase.dispute.dispute_evidence)
      end
    end

    context "when the associated product is a membership" do
      let(:disputed_purchase) do
        create(
          :membership_purchase,
          price_cents: 100,
          url_redirect: create(:url_redirect),
          chargeable: build(:chargeable_success_charge_disputed),
          chargeback_date: Time.current
        )
      end

      it "includes the cancellation_policy's Stripe file id in the dispute evidence" do
        allow(Stripe::File).to receive(:create).and_return(double(id: "cancellation_policy_file"))
        stripe_charge.refresh
        expect(Stripe::Dispute).to receive(:update).with(
          stripe_charge.dispute,
          evidence: hash_including({ cancellation_policy: "cancellation_policy_file" })
        )

        subject.fight_chargeback(charge_id, disputed_purchase.dispute.dispute_evidence)
      end
    end
  end

  describe "#setup_future_charges!" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:stripe_card) { StripePaymentMethodHelper.success }
    let(:payment_method_id) { stripe_card.to_stripejs_payment_method_id }
    let(:customer_id) { stripe_card.to_stripejs_customer_id }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, customer_id:, zip_code: "12345", product_permalink: "xx") }

    it "creates a setup intent" do
      expect(Stripe::SetupIntent).to receive(:create).with(hash_including(payment_method: payment_method_id, customer: customer_id)).and_call_original
      setup_intent = subject.setup_future_charges!(merchant_account, chargeable)

      expect(setup_intent).to be_a(StripeSetupIntent)
      expect(setup_intent.succeeded?).to eq(true)
      expect(setup_intent.requires_action?).to eq(false)
    end

    context "for a managed Stripe account" do
      let(:user) { create(:user) }
      let(:stripe_account) { create_verified_stripe_account(country: "US") }

      let(:merchant_account) do
        create(:merchant_account, user:, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: stripe_account.id)
      end

      it "creates a setup intent on behalf of a managed account" do
        expect(Stripe::SetupIntent).to receive(:create).with(hash_including(payment_method: payment_method_id, customer: customer_id)).and_call_original
        subject.setup_future_charges!(merchant_account, chargeable)
      end
    end

    context "for a card with SCA support" do
      let(:stripe_card) { StripePaymentMethodHelper.success_with_sca }

      it "creates a setup intent that requires action" do
        expect(Stripe::SetupIntent).to receive(:create).with(hash_including(payment_method: payment_method_id, customer: customer_id)).and_call_original
        setup_intent = subject.setup_future_charges!(merchant_account, chargeable)

        expect(setup_intent).to be_a(StripeSetupIntent)
        expect(setup_intent.succeeded?).to eq(false)
        expect(setup_intent.requires_action?).to eq(true)
      end
    end

    # https://support.stripe.com/questions/faqs-for-setup-intents-and-payment-intents-api-recurring-charges-from-indian-cardholders
    describe "Support for RBI regulations for Indian cards" do
      let(:manual_3ds_params) { { payment_method_options: { card: { request_three_d_secure: "any" } } } }

      context "for an Indian card with SCA support" do
        let(:stripe_card) { StripePaymentMethodHelper.build(number: "4000003560000008") } # https://stripe.com/docs/testing#international-cards

        it "ignores the default Radar rules and always requests 3DS" do
          expect(Stripe::SetupIntent).to receive(:create).with(hash_including(manual_3ds_params)).and_call_original
          setup_intent = subject.setup_future_charges!(merchant_account, chargeable)

          expect(setup_intent).to be_a(StripeSetupIntent)
          expect(setup_intent.succeeded?).to eq(false)
          expect(setup_intent.requires_action?).to eq(true)
        end

        it "creates a mandate if future off-session charges are required" do
          mandate_options = {
            payment_method_options: {
              card: {
                mandate_options: {
                  reference: StripeChargeProcessor::MANDATE_PREFIX + "UniqueMandateID",
                  amount_type: "maximum",
                  amount: 10_00,
                  currency: "usd",
                  start_date: Date.new(2023, 12, 25).to_time.to_i,
                  interval: "sporadic",
                  supported_types: ["india"]
                },
                request_three_d_secure: "any"
              }
            }
          }

          expect(Stripe::SetupIntent).to receive(:create).with(hash_including(mandate_options)).and_call_original
          setup_intent = subject.setup_future_charges!(merchant_account, chargeable, mandate_options:)

          expect(setup_intent).to be_a(StripeSetupIntent)
          expect(setup_intent.succeeded?).to eq(false)
          expect(setup_intent.requires_action?).to eq(true)
        end
      end

      context "for a non-Indian card" do
        context "with SCA support" do
          let(:stripe_card) { StripePaymentMethodHelper.success_with_sca }

          it "follows the default Radar rules and does not request 3DS manually" do
            expect(Stripe::SetupIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
            setup_intent = subject.setup_future_charges!(merchant_account, chargeable)

            expect(setup_intent).to be_a(StripeSetupIntent)
            expect(setup_intent.succeeded?).to eq(false)
            expect(setup_intent.requires_action?).to eq(true)
          end
        end

        context "without SCA support" do
          let(:stripe_card) { StripePaymentMethodHelper.success }

          it "follows the default Radar rules and does not request 3DS manually" do
            expect(Stripe::SetupIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
            setup_intent = subject.setup_future_charges!(merchant_account, chargeable)

            expect(setup_intent).to be_a(StripeSetupIntent)
            expect(setup_intent.succeeded?).to eq(true)
            expect(setup_intent.requires_action?).to eq(false)
          end
        end
      end
    end
  end

  describe "#create_payment_intent_or_charge!" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, zip_code: "12345", product_permalink: "xx") }

    it "creates payment intent" do
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(payment_method: payment_method_id)).and_call_original
      subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
    end

    it "passes on the reference" do
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(metadata: hash_including(purchase: "reference"))).and_call_original
      subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
    end

    it "passes on the description" do
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(description: "test description")).and_call_original
      subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
    end

    context "for a card without SCA support" do
      let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }

      it "returns a successful StripeChargeIntent with a charge" do
        charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")

        expect(charge_intent).to be_a(StripeChargeIntent)
        expect(charge_intent.succeeded?).to eq(true)
        expect(charge_intent.requires_action?).to eq(false)
        expect(charge_intent.charge).to be_a(StripeCharge)
      end
    end

    context "for a card with SCA support" do
      let(:payment_method_id) { StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id }

      context "when on-session" do
        it "returns a StripeChargeIntent that requires action" do
          charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: false)

          expect(charge_intent).to be_a(StripeChargeIntent)
          expect(charge_intent.succeeded?).to eq(false)
          expect(charge_intent.requires_action?).to eq(true)
          expect(charge_intent.charge).to be_blank
        end
      end

      context "when off-session" do
        context "usage was prepared for card" do
          let(:payment_method_id) { StripePaymentMethodHelper.success_future_usage_set_up.to_stripejs_payment_method_id }

          it "returns a successful StripeChargeIntent" do
            charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: true)

            expect(charge_intent).to be_a(StripeChargeIntent)
            expect(charge_intent.succeeded?).to eq(true)
            expect(charge_intent.requires_action?).to eq(false)
            expect(charge_intent.charge).to be_a(StripeCharge)
          end
        end

        context "usage was not prepared for card" do
          it "fails with ChargeProcessorCardError" do
            expect do
              subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: true)
            end.to raise_error(ChargeProcessorCardError)
          end
        end
      end
    end

    # https://support.stripe.com/questions/faqs-for-setup-intents-and-payment-intents-api-recurring-charges-from-indian-cardholders
    describe "Support for RBI regulations for Indian cards" do
      before do
        chargeable.prepare!
      end

      let(:manual_3ds_params) { { payment_method_options: { card: { request_three_d_secure: "any" } } } }

      context "when off-session" do
        context "for an Indian card with SCA support" do
          let(:payment_method_id) { StripePaymentMethodHelper.build(number: "4000003560000008").to_stripejs_payment_method_id } # https://stripe.com/docs/testing#international-cards

          it "follows the default Radar rules and does not request 3DS manually" do
            expect(Stripe::PaymentIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
            charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: true)
            expect(charge_intent).to be_a(StripeChargeIntent)
          end
        end

        context "for a non-Indian card with SCA support" do
          let(:payment_method_id) { StripePaymentMethodHelper.success_future_usage_set_up.to_stripejs_payment_method_id }

          it "follows the default Radar rules and does not request 3DS manually" do
            expect(Stripe::PaymentIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
            charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: true)
            expect(charge_intent).to be_a(StripeChargeIntent)
          end
        end
      end

      context "when on-session" do
        context "when NOT setting up future usage" do
          context "for an Indian card with SCA support" do
            let(:payment_method_id) { StripePaymentMethodHelper.build(number: "4000003560000008").to_stripejs_payment_method_id } # https://stripe.com/docs/testing#international-cards

            it "follows the default Radar rules and does not request 3DS manually" do
              expect(Stripe::PaymentIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
              charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: false)
              expect(charge_intent).to be_a(StripeChargeIntent)
            end
          end

          context "for a non-Indian card with SCA support" do
            let(:payment_method_id) { StripePaymentMethodHelper.success_future_usage_set_up.to_stripejs_payment_method_id }

            it "follows the default Radar rules and does not request 3DS manually" do
              expect(Stripe::PaymentIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
              charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: false)
              expect(charge_intent).to be_a(StripeChargeIntent)
            end
          end
        end

        context "when setting up future usage" do
          context "for an Indian card with SCA support" do
            let(:payment_method_id) { StripePaymentMethodHelper.build(number: "4000003560000008").to_stripejs_payment_method_id } # https://stripe.com/docs/testing#international-cards

            it "ignores the default Radar rules and always requests 3DS" do
              expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(manual_3ds_params)).and_call_original
              charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: false, setup_future_charges: true)
              expect(charge_intent).to be_a(StripeChargeIntent)
            end
          end

          context "for a non-Indian card with SCA support" do
            let(:payment_method_id) { StripePaymentMethodHelper.success_future_usage_set_up.to_stripejs_payment_method_id }

            it "follows the default Radar rules and does not request 3DS manually" do
              expect(Stripe::PaymentIntent).to receive(:create).with(hash_excluding(manual_3ds_params)).and_call_original
              charge_intent = subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: false, setup_future_charges: true)
              expect(charge_intent).to be_a(StripeChargeIntent)
            end
          end
        end
      end
    end

    describe "if a reusable token has been requested already" do
      let(:reusable_token) { chargeable.reusable_token!(nil) }

      it "charges the persistable token (stripe customer)" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(customer: reusable_token)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description", off_session: false)
      end
    end

    it "does not set a destination since it's on our stripe account" do
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_not_including(destination: anything)).and_call_original
      subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 0_30, "reference", "test description")
    end

    describe "on the merchant account mirroring a Stripe managed account" do
      let(:user) { create(:user) }
      let(:stripe_account) { create_verified_stripe_account(country: "US") }

      let(:merchant_account) do
        create(:merchant_account, user:, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: stripe_account.id)
      end

      it "creates payment intent" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(payment_method: payment_method_id)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 100, 30, "reference", "test description")
      end

      describe "if a reusable token has been requested already" do
        let(:reusable_token) { chargeable.reusable_token!(nil) }

        it "charges the persistable token (stripe customer)" do
          expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(customer: reusable_token)).and_call_original
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 100, 30, "reference", "test description", off_session: false)
        end
      end

      it "sets a stripe_account for the managed account" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(transfer_data: { destination: stripe_account.id, amount: 70 })).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 100, 30, "reference", "test description")
      end

      it "sets the application fee to gumroad's portion of the transaction" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(transfer_data: { destination: stripe_account.id, amount: 70 })).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 100, 30, "reference", "test description")
      end

      describe "if the charge_processor_merchant_id isn't set for some reason" do
        describe "nil" do
          before do
            merchant_account.charge_processor_merchant_id = nil
          end

          it "raises an error" do
            expect do
              subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 0_30, "reference", "test description")
            end.to raise_error("Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} but has no Charge Processor Merchant ID.")
          end
        end

        describe "empty string" do
          before do
            merchant_account.charge_processor_merchant_id = ""
          end

          it "raises an error" do
            expect do
              subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 0_30, "reference", "test description")
            end.to raise_error("Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} but has no Charge Processor Merchant ID.")
          end
        end
      end
    end

    describe "card error" do
      describe "card declined" do
        let(:payment_method_id) { StripePaymentMethodHelper.decline.to_stripejs_payment_method_id }

        it "raises an error" do
          expect { subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description") }.to raise_error(ChargeProcessorCardError)
        end

        it "raises an error containing card_declined error code" do
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
        rescue ChargeProcessorCardError => e
          expect(e.error_code).to eq("card_declined_generic_decline")
        end

        it "raises an error containing the charge id" do
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
        rescue ChargeProcessorCardError => e
          expect(e.charge_id).to start_with("ch_")
        end
      end

      describe "incorrect cvc" do
        let(:payment_method_id) { StripePaymentMethodHelper.decline_cvc_check_fails.to_stripejs_payment_method_id }

        it "raises an error" do
          expect { subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description") }.to raise_error(ChargeProcessorCardError)
        end

        it "raises an error containing incorrect_cvc error code" do
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
        rescue ChargeProcessorCardError => e
          expect(e.error_code).to eq("incorrect_cvc")
        end

        it "raises an error containing the charge id" do
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
        rescue ChargeProcessorCardError => e
          expect(e.charge_id).to start_with("ch_")
        end
      end

      describe "card declined due to Stripe expecting it's fraudulent" do
        let(:payment_method_id) { StripePaymentMethodHelper.decline_fraudulent.to_stripejs_payment_method_id }

        it "raises an error" do
          expect { subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description") }.to raise_error(ChargeProcessorCardError)
        end

        it "raises an error containing card_declined error code" do
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
        rescue ChargeProcessorCardError => e
          expect(e.error_code).to eq("card_declined_fraudulent")
        end

        it "raises an error containing the charge id" do
          subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "test description")
        rescue ChargeProcessorCardError => e
          expect(e.charge_id).to start_with("ch_")
        end
      end
    end

    describe "statement description provided" do
      it "is sent if the statement description is provided" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(statement_descriptor_suffix: "Josiah Carberr")).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: "Josiah Carberr")
      end

      it "allows dot and slashes but limit to 22 chars" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(statement_descriptor_suffix: "GUM.CO/CC Josiah Carbe")).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: "GUM.CO/CC Josiah Carberr")
      end

      it "sanitizes the statement description" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(statement_descriptor_suffix: "Josiah Carberry")).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: "Josiah!@日本語 Carberry")
      end

      it "is not sent if the statement description is blank" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_not_including(:statement_descriptor_suffix)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: "")
      end

      it "is not sent if the statement description is nil" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_not_including(:statement_descriptor_suffix)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: nil)
      end

      it "is not sent if the statement description is not provided" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_not_including(:statement_descriptor_suffix)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description")
      end

      it "is not sent if the statement description only has invalid characters" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_not_including(:statement_descriptor_suffix)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: "日本語日本語")
      end

      it "is not sent if the statement description only has invalid characters with whitespace" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_not_including(:statement_descriptor_suffix)).and_call_original
        subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", statement_description: "日本語 日本語")
      end
    end
  end

  describe "#get_charge_intent" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, zip_code: "12345", product_permalink: "xx") }
    let(:charge_intent_id) { subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description").id }

    it "returns a ChargeIntent object" do
      charge_intent = subject.get_charge_intent(charge_intent_id, merchant_account:)

      expect(charge_intent).to be_kind_of(ChargeIntent)
      expect(charge_intent.id).to eq(charge_intent_id)
    end

    context "when a blank charge intent ID is passed" do
      it "raises an error" do
        expect do
          subject.get_charge_intent(nil, merchant_account:)
        end.to raise_error ChargeProcessorInvalidRequestError
      end
    end

    context "when non-existing charge intent ID is passed" do
      it "raises an error" do
        expect do
          subject.get_charge_intent("does not exist", merchant_account:)
        end.to raise_error ChargeProcessorInvalidRequestError
      end
    end
  end

  describe "#get_setup_intent" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, zip_code: "12345", product_permalink: "xx") }
    let(:setup_intent_id) { subject.setup_future_charges!(merchant_account, chargeable).id }

    it "returns a SetupIntent object" do
      setup_intent = subject.get_setup_intent(setup_intent_id, merchant_account:)

      expect(setup_intent).to be_kind_of(SetupIntent)
      expect(setup_intent.id).to eq(setup_intent_id)
    end

    context "when a blank setup intent ID is passed" do
      it "raises an error" do
        expect do
          subject.get_setup_intent(nil, merchant_account:)
        end.to raise_error ChargeProcessorInvalidRequestError
      end
    end

    context "when non-existing setup intent ID is passed" do
      it "raises an error" do
        expect do
          subject.get_setup_intent("does not exist", merchant_account:)
        end.to raise_error ChargeProcessorInvalidRequestError
      end
    end
  end

  describe "#confirm_payment_intent!" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, zip_code: "12345", product_permalink: "xx") }
    let(:charge_intent_id) { subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description").id }

    context "when SCA was not performed" do
      let(:payment_method_id) { StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id }

      it "fails with ChargeProcessorCardError" do
        expect do
          subject.confirm_payment_intent!(merchant_account, charge_intent_id)
        end.to raise_error(ChargeProcessorCardError)
      end
    end

    context "when SCA was performed" do
      let(:payment_method_id) { StripePaymentMethodHelper.success_sca_not_required.to_stripejs_payment_method_id }
      let(:charge_intent_id) do
        charge_intent = Stripe::PaymentIntent.create(
          payment_method: payment_method_id,
          amount: 1_00,
          currency: "usd",
          payment_method_types: ["card"],
        )
        charge_intent.id
      end

      it "confirms the payment intent" do
        charge_intent = subject.confirm_payment_intent!(merchant_account, charge_intent_id)

        expect(charge_intent).to be_a(StripeChargeIntent)
        expect(charge_intent.succeeded?).to eq(true)
        expect(charge_intent.charge).to be_a(StripeCharge)
      end
    end
  end

  describe "#cancel_payment_intent!" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, zip_code: "12345", product_permalink: "xx") }
    let(:charge_intent_id) { subject.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 30, "reference", "the description", off_session: false).id }

    context "when intent is pending SCA" do
      let(:payment_method_id) { StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id }

      it "cancels intent" do
        subject.cancel_payment_intent!(merchant_account, charge_intent_id)

        stripe_payment_intent = Stripe::PaymentIntent.retrieve(charge_intent_id)
        expect(stripe_payment_intent.status).to eq("canceled")
      end
    end

    context "when intent has already succeeded" do
      let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }

      it "fails with ChargeProcessorError" do
        expect { subject.cancel_payment_intent!(merchant_account, charge_intent_id) }.to raise_error(ChargeProcessorError)
      end
    end
  end

  describe "#cancel_setup_intent!" do
    let(:merchant_account) { create(:merchant_account, user: nil, charge_processor_id: described_class.charge_processor_id, charge_processor_merchant_id: nil) }
    let(:chargeable) { StripeChargeablePaymentMethod.new(payment_method_id, zip_code: "12345", product_permalink: "xx") }
    let(:setup_intent_id) { subject.setup_future_charges!(merchant_account, chargeable).id }

    context "when intent is pending SCA" do
      let(:payment_method_id) { StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id }

      it "cancels intent" do
        subject.cancel_setup_intent!(merchant_account, setup_intent_id)

        stripe_setup_intent = Stripe::SetupIntent.retrieve(setup_intent_id)
        expect(stripe_setup_intent.status).to eq("canceled")
      end
    end

    context "when intent has already succeeded" do
      let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }

      it "fails with ChargeProcessorError" do
        expect do
          subject.cancel_setup_intent!(merchant_account, setup_intent_id)
        end.to raise_error(ChargeProcessorError, /You cannot cancel this SetupIntent because it has a status of succeeded./)
      end
    end
  end

  describe "#refund!" do
    let(:currency) { Currency::USD }
    let(:amount_cents) { 10_00 }
    let(:payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }
    let(:stripe_charge) { create_stripe_charge(payment_method_id, amount: amount_cents, currency:) }
    let(:charge_id) { stripe_charge.id }

    describe "full refund" do
      it "calls refund on the stripe charge without an amount" do
        expect(Stripe::Refund).to receive(:create).with({ charge: charge_id }).and_call_original
        subject.refund!(charge_id)
      end

      it "calls refund with reason if refund is for fraud" do
        expect(Stripe::Refund).to receive(:create).with({ charge: charge_id, reason: StripeChargeProcessor::REFUND_REASON_FRAUDULENT }).and_call_original
        subject.refund!(charge_id, is_for_fraud: true)
      end

      describe "return value" do
        let(:charge_refund) { subject.refund!(charge_id) }

        it "returns a StripeChargeRefund" do
          expect(charge_refund).to be_a(StripeChargeRefund)
        end

        it "returns a StripeChargeRefund with a simple flow_of_funds" do
          expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
          expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-amount_cents)
          expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(Currency::USD)
          expect(charge_refund.flow_of_funds.settled_amount.cents).to eq(-amount_cents)
          expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
          expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-amount_cents)
          expect(charge_refund.flow_of_funds.merchant_account_gross_amount).to be_nil
          expect(charge_refund.flow_of_funds.merchant_account_net_amount).to be_nil
        end
      end

      describe "stripe connect" do
        let(:destination_currency) { Currency::CAD }

        let(:application_fee) { 30 }

        let(:stripe_account) { create_verified_stripe_account(country: "CA", default_currency: destination_currency) }

        let(:stripe_charge) do
          create_stripe_charge(
            payment_method_id,
            amount: amount_cents,
            currency:,
            transfer_data: { destination: stripe_account },
            on_behalf_of: stripe_account,
            application_fee_amount: application_fee
          )
        end

        it "calls refund on the stripe charge with reverse transaction and refund fees" do
          expect(Stripe::Refund).to receive(:create).with({ charge: charge_id, reverse_transfer: true, refund_application_fee: true }).and_call_original
          subject.refund!(charge_id)
        end

        it "has refunded the application fee" do
          subject.refund!(charge_id)
          stripe_charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[application_fee])
          expect(stripe_charge.application_fee.refunded).to eq(true)
        end

        it "has reversed the transfer" do
          subject.refund!(charge_id)
          stripe_charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[transfer])
          expect(stripe_charge.transfer.reversed).to eq(true)
        end

        describe "return value" do
          let(:charge_refund) { subject.refund!(charge_id) }

          it "returns a StripeChargeRefund" do
            expect(charge_refund).to be_a(StripeChargeRefund)
          end

          it "returns a StripeChargeRefund with a flow_of_funds" do
            usd_to_cad = charge_refund.refund.balance_transaction.exchange_rate
            expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
            expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-amount_cents)
            expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.settled_amount.cents).to be_within(1).of(-10_00 * usd_to_cad)
            expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
            expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-application_fee)
            expect(charge_refund.flow_of_funds.merchant_account_gross_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.merchant_account_net_amount.currency).to eq(destination_currency)

            charge = Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[application_fee balance_transaction])
            destination_transfer = Stripe::Transfer.retrieve(id: charge.transfer)
            stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                                                   expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                                 { stripe_account: destination_transfer.destination })
            expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to eq(
              -stripe_destination_payment.refunds.first.amount
            )
            expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to eq(
              -(stripe_destination_payment.refunds.first.amount - charge.application_fee.refunds.first.amount)
            )
          end
        end

        describe "without application fee" do
          let(:destination_currency) { Currency::CAD }

          let(:stripe_account) { create_verified_stripe_account(country: "CA", default_currency: destination_currency) }

          let(:stripe_charge) do
            create_stripe_charge(
              payment_method_id,
              amount: amount_cents,
              currency:,
              transfer_data: { destination: stripe_account },
              on_behalf_of: stripe_account
            )
          end

          it "calls refund! on the stripe charge with reverse transaction and refund fees" do
            expect(Stripe::Refund).to receive(:create).with({ charge: charge_id, reverse_transfer: true, refund_application_fee: true }).and_call_original
            subject.refund!(charge_id)
          end

          it "does not have an application fee" do
            subject.refund!(charge_id)
            stripe_charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[application_fee])
            expect(stripe_charge.application_fee).to be(nil)
          end

          it "reverses the transfer" do
            subject.refund!(charge_id)
            stripe_charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[transfer])
            expect(stripe_charge.transfer.reversed).to eq(true)
          end

          describe "return value" do
            let(:charge_refund) { subject.refund!(charge_id) }

            it "returns a StripeChargeRefund" do
              expect(charge_refund).to be_a(StripeChargeRefund)
            end

            it "returns a StripeChargeRefund with a flow_of_funds" do
              charge = Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction])
              stripe_refund = Stripe::Refund.retrieve(id: charge_refund.id, expand: %w[balance_transaction])
              destination_transfer = Stripe::Transfer.retrieve(id: charge.transfer)
              stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                                                     expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                                   { stripe_account: destination_transfer.destination })
              expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(currency)
              expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-amount_cents)

              expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(destination_currency)
              expect(charge_refund.flow_of_funds.settled_amount.cents).to eq(-(amount_cents * stripe_refund.balance_transaction.exchange_rate).round)

              expect(charge_refund.flow_of_funds.gumroad_amount).to be(nil)

              expect(charge_refund.flow_of_funds.merchant_account_gross_amount.currency).to eq(destination_currency)
              expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to eq(-stripe_destination_payment.refunds.first.amount)

              expect(charge_refund.flow_of_funds.merchant_account_net_amount.currency).to eq(destination_currency)
              expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to eq(-stripe_destination_payment.refunds.first.amount)
            end
          end
        end

        describe "for a charge with affiliate and without on_behalf_of & application_fee_amount parameters" do
          let(:stripe_charge) do
            stripe_charge = create_stripe_charge(
              StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
              currency: "usd",
              amount: 10_00,
              transfer_data: { destination: stripe_account, amount: 7_70 },
              )
            stripe_charge.refresh
            stripe_charge
          end

          let!(:purchase) do
            product = create(:product)
            direct_affiliate = create(:direct_affiliate, seller: product.user, affiliate_basis_points: 2000, products: [product])
            create(:purchase, link: product, total_transaction_cents: 10_00, stripe_transaction_id: stripe_charge.id,
                              fee_cents: 30,
                              affiliate_credit_cents: 2_00,
                              affiliate: direct_affiliate)
          end

          it "returns a StripeChargeRefund with a flow_of_funds containing correct merchant and gumroad amounts" do
            charge_refund = subject.refund!(stripe_charge.id)

            charge = Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction])
            stripe_refund = Stripe::Refund.retrieve(id: charge_refund.id, expand: %w[balance_transaction])
            destination_transfer = Stripe::Transfer.retrieve(id: charge.transfer)
            stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                                                   expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                                 { stripe_account: destination_transfer.destination })
            expect(charge_refund).to be_a(StripeChargeRefund)
            expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(currency)
            expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-amount_cents)

            expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(currency)
            expect(charge_refund.flow_of_funds.settled_amount.cents).to eq(-amount_cents)

            expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(currency)
            expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(stripe_refund.amount - stripe_destination_payment.refunds.first.amount)

            expect(charge_refund.flow_of_funds.merchant_account_gross_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to eq(stripe_destination_payment.refunds.first.balance_transaction.amount)

            expect(charge_refund.flow_of_funds.merchant_account_net_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to eq(stripe_destination_payment.refunds.first.balance_transaction.amount)
          end
        end
      end

      describe "with standard stripe connect account" do
        let!(:stripe_charge_id) { "ch_3OFXziKQKir5qdfM1dSA3Ui0" }

        let!(:merchant_account) { create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM") }

        let!(:stripe_charge) do
          Stripe::Charge.retrieve(stripe_charge_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        end

        it "calls refund on the stripe charge with refund_application_fee flag set to false" do
          expect(Stripe::Refund).to receive(:create).with({ charge: stripe_charge_id, refund_application_fee: false }, { stripe_account: merchant_account.charge_processor_merchant_id }).and_call_original

          subject.refund!(charge_id, merchant_account:)
        end
      end

      describe "already refunded" do
        before do
          subject.refund!(charge_id)
        end

        it "raises already refunded error" do
          expect { subject.refund!(charge_id) }.to raise_error(ChargeProcessorAlreadyRefundedError)
        end
      end

      describe "error with charge id" do
        it "raises invalid request error" do
          expect { subject.refund!("invalid-charge-id") }.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end

      describe "error accessing stripe due to connection error" do
        before do
          expect(Stripe::Refund).to receive(:create).and_raise(Stripe::APIConnectionError)
        end

        it "raises unavailable error" do
          expect { subject.refund!(charge_id) }.to raise_error(ChargeProcessorUnavailableError)
        end
      end
      describe "error accessing stripe due to api error" do
        before do
          expect(Stripe::Refund).to receive(:create).and_raise(Stripe::APIError)
        end

        it "raises unavailable error" do
          expect { subject.refund!(charge_id) }.to raise_error(ChargeProcessorUnavailableError)
        end
      end
    end

    describe "partial refund" do
      let(:refund_amount_cents) { 5_00 }

      it "calls refund on the stripe charge with an amount" do
        expect(Stripe::Refund).to receive(:create).with({ charge: charge_id, amount: refund_amount_cents }).and_call_original
        subject.refund!(charge_id, amount_cents: refund_amount_cents)
      end

      it "returns a StripeChargeRefund" do
        expect(subject.refund!(charge_id, amount_cents: refund_amount_cents)).to be_a(StripeChargeRefund)
      end

      describe "return value" do
        let(:charge_refund) { subject.refund!(charge_id, amount_cents: refund_amount_cents) }

        it "returns a StripeChargeRefund" do
          expect(charge_refund).to be_a(StripeChargeRefund)
        end

        it "returns a StripeChargeRefund with a simple flow_of_funds" do
          expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
          expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-refund_amount_cents)
          expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(Currency::USD)
          expect(charge_refund.flow_of_funds.settled_amount.cents).to eq(-refund_amount_cents)
          expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
          expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-refund_amount_cents)
          expect(charge_refund.flow_of_funds.merchant_account_gross_amount).to be_nil
          expect(charge_refund.flow_of_funds.merchant_account_net_amount).to be_nil
        end
      end

      describe "stripe connect" do
        let(:destination_currency) { Currency::CAD }

        let(:application_fee) { 30 }

        let(:stripe_account) { create_verified_stripe_account(country: "CA", default_currency: destination_currency) }

        let(:stripe_charge) do
          create_stripe_charge(
            payment_method_id,
            amount: amount_cents,
            currency:,
            transfer_data: { destination: stripe_account },
            on_behalf_of: stripe_account,
            application_fee_amount: application_fee
          )
        end

        it "calls refund on the stripe charge with the amount" do
          expect(Stripe::Refund).to receive(:create).with({ charge: charge_id, amount: refund_amount_cents, refund_application_fee: true, reverse_transfer: true }).and_call_original
          subject.refund!(charge_id, amount_cents: refund_amount_cents)
        end

        it "has not refunded the application fee" do
          subject.refund!(charge_id, amount_cents: refund_amount_cents)
          stripe_charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[application_fee])
          expect(stripe_charge.application_fee.refunded).to eq(false)
        end

        it "has not reversed the transfer" do
          subject.refund!(charge_id, amount_cents: refund_amount_cents)
          stripe_charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[transfer])
          expect(stripe_charge.transfer.reversed).to eq(false)
        end

        describe "return value" do
          let(:charge_refund) { subject.refund!(charge_id, amount_cents: refund_amount_cents) }

          it "returns a StripeChargeRefund" do
            expect(charge_refund).to be_a(StripeChargeRefund)
          end

          it "returns a StripeChargeRefund with a flow_of_funds" do
            usd_to_cad = charge_refund.charge.balance_transaction.exchange_rate
            expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
            expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-refund_amount_cents)
            expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.settled_amount.cents).to be_within(1).of(-5_00 * charge_refund.refund.balance_transaction.exchange_rate)
            expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
            expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-15) # 1/2 of application fee; proportional to refund amount
            expect(charge_refund.flow_of_funds.merchant_account_gross_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to be_within(1).of(-5_00 * usd_to_cad)
            expect(charge_refund.flow_of_funds.merchant_account_net_amount.currency).to eq(destination_currency)
            expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to be_within(1).of(-4_85 * usd_to_cad) # 4_85 = 5_00 (gross merchant amount) - 15 (application fee)
          end
        end
      end

      describe "already fully refunded" do
        before do
          subject.refund!(charge_id, amount_cents: 10_00)
        end

        it "raises already refunded error" do
          expect { subject.refund!(charge_id, amount_cents: 1_00) }.to raise_error(ChargeProcessorAlreadyRefundedError)
        end
      end

      describe "refunding more than original amount" do
        it "raises invalid request error" do
          expect { subject.refund!(charge_id, amount_cents: 11_00) }.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end

      describe "multiple refunds" do
        before do
          subject.refund!(charge_id, amount_cents: 5_00)
        end

        it "allows a second partial refund" do
          expect { subject.refund!(charge_id, amount_cents: 5_00) }.to_not raise_error
        end

        describe "when total partials would be more than original" do
          it "raises invalid request error" do
            expect { subject.refund!(charge_id, amount_cents: 6_00) }.to raise_error(ChargeProcessorInvalidRequestError)
          end
        end

        describe "stripe connect" do
          let(:destination_currency) { Currency::CAD }

          let(:application_fee) { 30 }

          let(:stripe_account) { create_verified_stripe_account(country: "CA", default_currency: destination_currency) }

          let(:stripe_charge) do
            create_stripe_charge(
              payment_method_id,
              amount: amount_cents,
              currency:,
              transfer_data: { destination: stripe_account },
              on_behalf_of: stripe_account,
              application_fee_amount: application_fee
            )
          end

          describe "refund another portion" do
            describe "return value" do
              let(:charge_refund) { subject.refund!(charge_id, amount_cents: 1_00) }

              it "returns a StripeChargeRefund" do
                expect(charge_refund).to be_a(StripeChargeRefund)
              end

              it "returns a StripeChargeRefund with a flow_of_funds" do
                usd_to_cad = charge_refund.charge.balance_transaction.exchange_rate
                expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
                expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-1_00)
                expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.settled_amount.cents).to be_within(1).of(-1_00 * usd_to_cad)
                expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
                expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-3) # 1/10th of the charge amount; proportional to refund_amount
                expect(charge_refund.flow_of_funds.merchant_account_gross_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to be_within(1).of(-1_00 * usd_to_cad)
                expect(charge_refund.flow_of_funds.merchant_account_net_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to be_within(1).of(-97 * usd_to_cad)
              end
            end
          end

          describe "refund another portion that happens to be all remaining" do
            describe "return value" do
              let(:charge_refund) { subject.refund!(charge_id, amount_cents: 5_00) }

              it "returns a StripeChargeRefund" do
                expect(charge_refund).to be_a(StripeChargeRefund)
              end

              it "returns a StripeChargeRefund with a flow_of_funds" do
                usd_to_cad = charge_refund.charge.balance_transaction.exchange_rate
                expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
                expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-5_00)
                expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.settled_amount.cents).to be_within(1).of(-5_00 * usd_to_cad)
                expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
                expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-15) # 1/2 of application fee; proportional to refund amount
                expect(charge_refund.flow_of_funds.merchant_account_gross_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to be_within(1).of(-5_00 * usd_to_cad)
                expect(charge_refund.flow_of_funds.merchant_account_net_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to be_within(1).of(-4_85 * usd_to_cad) # 4_85 = 5_00 (gross merchant amount) - 15 (application fee)
              end
            end
          end

          describe "refund all remaining" do
            describe "return value" do
              let(:charge_refund) { subject.refund!(charge_id) }

              it "returns a StripeChargeRefund" do
                expect(charge_refund).to be_a(StripeChargeRefund)
              end

              it "returns a StripeChargeRefund with a flow_of_funds" do
                usd_to_cad = charge_refund.charge.balance_transaction.exchange_rate
                expect(charge_refund.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
                expect(charge_refund.flow_of_funds.issued_amount.cents).to eq(-5_00)
                expect(charge_refund.flow_of_funds.settled_amount.currency).to eq(destination_currency)
                expect(charge_refund.flow_of_funds.settled_amount.cents).to be_within(1).of(-5_00 * usd_to_cad)
                expect(charge_refund.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
                expect(charge_refund.flow_of_funds.gumroad_amount.cents).to eq(-15) # 1/2 of application fee; proportional to refund amount

                charge = Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[application_fee balance_transaction])
                destination_transfer = Stripe::Transfer.retrieve(id: charge.transfer)
                stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                                                       expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                                     { stripe_account: destination_transfer.destination })
                expect(charge_refund.flow_of_funds.merchant_account_gross_amount.cents).to eq(
                  -stripe_destination_payment.refunds.first.amount
                )
                expect(charge_refund.flow_of_funds.merchant_account_net_amount.cents).to eq(
                  -(stripe_destination_payment.refunds.first.amount - stripe_destination_payment.application_fee.refunds.first.amount)
                )
              end
            end
          end
        end
      end

      describe "error with charge id" do
        it "raises invalid request error" do
          expect { subject.refund!("invalid-charge-id", amount_cents: 5_00) }.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end

      describe "error accessing stripe due to connection error" do
        before do
          expect(Stripe::Refund).to receive(:create).and_raise(Stripe::APIConnectionError)
        end

        it "raises unavailable error" do
          expect { subject.refund!(charge_id, amount_cents: 5_00) }.to raise_error(ChargeProcessorUnavailableError)
        end
      end

      describe "error accessing stripe due to api error" do
        before do
          expect(Stripe::Refund).to receive(:create).and_raise(Stripe::APIError)
        end
        it "raises unavailable error" do
          expect { subject.refund!(charge_id, amount_cents: 5_00) }.to raise_error(ChargeProcessorUnavailableError)
        end
      end
    end
  end

  describe "holder_of_funds" do
    describe "merchant account is a stripe managed account" do
      let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }

      it "returns Gumroad" do
        expect(subject.holder_of_funds(merchant_account)).to eq(HolderOfFunds::GUMROAD)
      end
    end

    describe "merchant account is not a stripe managed account" do
      let(:merchant_account) { create(:merchant_account) }

      it "returns Stripe" do
        expect(subject.holder_of_funds(merchant_account)).to eq(HolderOfFunds::STRIPE)
      end
    end
  end

  describe ".handle_stripe_event" do
    let(:stripe_event_id) { "evt_eventid" }
    let(:stripe_charge_id) { "charge-id" }
    let(:stripe_event_type) { raise "Define `stripe_event_type` in your `handle_stripe_event` test." }
    let(:stripe_event_object) { raise "Define `stripe_event_object` in your `handle_stripe_event` test." }
    let(:stripe_event) do
      {
        "id" => stripe_event_id,
        "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
        "type" => stripe_event_type,
        "data" => {
          "object" => stripe_event_object
        }
      }
    end

    describe "event object unrecognised" do
      let(:stripe_event_type) { "invoice.created" }
      let(:stripe_event_object) { { "object" => "invoice" } }

      it "calls charge processors handle event with correct event info" do
        expect(ChargeProcessor).to_not(receive(:handle_event))
        StripeChargeProcessor.handle_stripe_event(stripe_event)
      end
    end

    describe "event object: charge" do
      let(:stripe_event_type) { "charge.happened" }
      let(:stripe_event_object) { { "object" => "charge", "metadata" => "hi", "id" => stripe_charge_id } }

      it "calls charge processors handle event with correct event info" do
        expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original
        StripeChargeProcessor.handle_stripe_event(stripe_event)
      end

      describe "event charge succeeded" do
        let(:stripe_event_type) { "charge.succeeded" }
        let(:purchase_external_id) { "qMqa0TLcYiy4yKiY_EHQKQ==" }
        let(:stripe_event) do
          {
            "id" => "evt_2ORDpK9e1RjUNIyY09crh62H",
            "object" => "event",
            "account" => "9e1RjUNIyYGpA9Cfh3RmQxxTzb1aakpE",
            "api_version" => "2023-10-16",
            "created" => 1703509963,
            "data" => {
              "object" => {
                "id" => "ch_2ORDpK9e1RjUNIyY0eJyh91P",
                "object" => "charge",
                "amount" => 1705,
                "amount_captured" => 1705,
                "amount_refunded" => 0,
                "application" => nil,
                "application_fee" => nil,
                "application_fee_amount" => nil,
                "balance_transaction" => "txn_2ORDpK9e1RjUNIyY0D2RrELS",
                "billing_details" => {
                  "address" => {
                    "city" => nil,
                    "country" => nil,
                    "line1" => nil,
                    "line2" => nil,
                    "postal_code" => "",
                    "state" => nil
                  },
                  "email" => nil,
                  "name" => nil,
                  "phone" => nil
                },
                "calculated_statement_descriptor" => "GUMRD.COM* 55571275760",
                "captured" => true,
                "created" => 1703509957,
                "currency" => "usd",
                "customer" => "cus_PFjCvrVcjT3anY",
                "description" => "You bought https://5557127576064.gumroad.dev/l/mb",
                "destination" => "acct_1MltEr2mZ9S5oOnc",
                "dispute" => nil,
                "disputed" => false,
                "failure_balance_transaction" => nil,
                "failure_code" => nil,
                "failure_message" => nil,
                "fraud_details" => {},
                "invoice" => nil,
                "livemode" => false,
                "metadata" => {
                  "purchase" => "qMqa0TLcYiy4yKiY_EHQKQ=="
                },
                "on_behalf_of" => nil,
                "order" => nil,
                "outcome" => {
                  "network_status" => "approved_by_network",
                  "reason" => nil,
                  "risk_level" => "normal",
                  "risk_score" => 21,
                  "seller_message" => "Payment complete.",
                  "type" => "authorized"
                },
                "paid" => true,
                "payment_intent" => "pi_2ORDpK9e1RjUNIyY0HzsOweC",
                "payment_method" => "pm_0ORDjt9e1RjUNIyYKOfpIQNI",
                "payment_method_details" => {
                  "card" => {
                    "amount_authorized" => 1705,
                    "brand" => "visa",
                    "checks" => {
                      "address_line1_check" => nil,
                      "address_postal_code_check" => nil,
                      "cvc_check" => nil
                    },
                    "country" => Compliance::Countries::IND.alpha2,
                    "exp_month" => 12,
                    "exp_year" => 2034,
                    "extended_authorization" => {
                      "status" => "disabled"
                    },
                    "fingerprint" => "Jc8MwNDiNvhPqNky",
                    "funding" => "credit",
                    "incremental_authorization" => {
                      "status" => "unavailable"
                    },
                    "installments" => nil,
                    "last4" => "0123",
                    "mandate" => nil,
                    "multicapture" => {
                      "status" => "unavailable"
                    },
                    "network" => "visa",
                    "network_token" => {
                      "used" => false
                    },
                    "overcapture" => {
                      "maximum_amount_capturable" => 1705,
                      "status" => "unavailable"
                    },
                    "three_d_secure" => nil,
                    "wallet" => nil
                  },
                  "type" => "card"
                },
                "radar_options" => {},
                "receipt_email" => nil,
                "receipt_number" => nil,
                "receipt_url" => "https://pay.stripe.com/receipts/payment/CAcaIgogOWUxUmpVTkl5WUdwQTlDZmgzUm1ReHhUemIxYWFrcEUoyv-lrAYyBpZkLXKmpzosFtE_G_bNU3FdP_bLsEB2Yqebx1WRowK1WL2lvnXkk0khgSgBG4kYP8Pa97I",
                "refunded" => false,
                "review" => nil,
                "shipping" => nil,
                "source" => nil,
                "source_transfer" => nil,
                "statement_descriptor" => nil,
                "statement_descriptor_suffix" => "5557127576064",
                "status" => "succeeded",
                "transfer" => "tr_2ORDpK9e1RjUNIyY0qZQ2QFQ",
                "transfer_data" => {
                  "amount" => 1455,
                  "destination" => "acct_1MltEr2mZ9S5oOnc"
                },
                "transfer_group" => "1231"
              }
            },
            "livemode" => false,
            "pending_webhooks" => 5,
            "request" => {
              "id" => nil,
              "idempotency_key" => nil
            },
            "type" => "charge.succeeded"
          }
        end

        it "works as only informational event if corresponding purchase is not on an Indian card" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase, id: ObfuscateIds.decrypt(purchase_external_id))
          expect_any_instance_of(Purchase).to receive(:handle_event_succeeded!).and_call_original
          expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
          expect_any_instance_of(Purchase).not_to receive(:save_charge_data)
          expect_any_instance_of(Purchase).not_to receive(:mark_successful!)
          allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(purchase)

          StripeChargeProcessor.handle_stripe_event(stripe_event)
        end

        it "works as only informational event if corresponding purchase is not an off-session purchase" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase, id: ObfuscateIds.decrypt(purchase_external_id), card_country: Compliance::Countries::IND.alpha2)
          expect_any_instance_of(Purchase).to receive(:handle_event_succeeded!).and_call_original
          expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
          expect_any_instance_of(Purchase).not_to receive(:save_charge_data)
          expect_any_instance_of(Purchase).not_to receive(:mark_successful!)
          allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(purchase)

          StripeChargeProcessor.handle_stripe_event(stripe_event)
        end

        it "marks the corresponding purchase successful if it's in progress for an off-session charge on an Indian card" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          original_membership_purchase = create(:membership_purchase)
          recurring_membership_purchase = create(
            :purchase,
            subscription: original_membership_purchase.subscription,
            purchase_state: "in_progress",
            id: ObfuscateIds.decrypt(purchase_external_id),
            card_country: Compliance::Countries::IND.alpha2
          )
          expect_any_instance_of(Purchase).to receive(:handle_event_succeeded!).and_call_original
          expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
          expect_any_instance_of(Purchase).to receive(:save_charge_data).and_call_original
          expect_any_instance_of(Purchase).to receive(:update_balance_and_mark_successful!).and_call_original
          allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(recurring_membership_purchase)

          StripeChargeProcessor.handle_stripe_event(stripe_event)

          expect(recurring_membership_purchase.reload.successful?).to be true
          expect(recurring_membership_purchase.stripe_transaction_id).to eq(stripe_event["data"]["object"]["id"])
        end
      end

      describe "event charge refund updated" do
        let(:stripe_event_type) { "charge.refund.updated" }

        let(:stripe_event) do
          {
            "id" => "evt_2Q7bRK9e1RjUNIyY1R1OIZDn",
            "object" => "event",
            "api_version" => "2023-10-16",
            "created" => 1728386835,
            "data" => {
              "object" => {
                "id" => "re_2Q7bRK9e1RjUNIyY1icyswlr",
                "object" => "refund",
                "amount" => 1700,
                "balance_transaction" => "txn_2Q7bRK9e1RjUNIyY1hpvIOPN",
                "charge" => "ch_2Q7bRK9e1RjUNIyY1SMUhNqu",
                "created" => 1728386832,
                "currency" => "usd",
                "destination_details" => {
                  "card" => {
                    "reference" => "9737533023580908",
                    "reference_status" => "available",
                    "reference_type" => "acquirer_reference_number",
                    "type" => "refund"
                  },
                  "type" => "card"
                },
                "metadata" => {},
                "payment_intent" => "pi_2Q7bRK9e1RjUNIyY1J2BBTCh",
                "reason" => "fraudulent",
                "receipt_number" => nil,
                "source_transfer_reversal" => nil,
                "status" => "succeeded",
                "transfer_reversal" => "trr_0Q7bZN9e1RjUNIyYH7vxI14k"
              },
              "previous_attributes" => {
                "destination_details" => {
                  "card" => {
                    "reference_status" => "pending",
                    "reference" => nil
                  }
                }
              }
            },
            "livemode" => false,
            "pending_webhooks" => 2,
            "request" => {
              "id" => nil,
              "idempotency_key" => nil
            },
            "type" => "charge.refund.updated"
          }
        end

        it "refunds the purchase corresponding to the Stripe charge" do
          stripe_event["data"]["object"]["reason"] = "requested_by_customer"

          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase,
                            price_cents: 1700,
                            total_transaction_cents: 1700,
                            stripe_transaction_id: "ch_2Q7bRK9e1RjUNIyY1SMUhNqu")
          expect_any_instance_of(Purchase).to receive(:handle_event_refund_updated!).and_call_original

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded).with(purchase.id)
             .and not_have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded_for_fraud)

          expect(purchase.reload.stripe_refunded?).to be true
          expect(purchase.refunds.count).to eq 1
          expect(purchase.refunds.last.amount_cents).to eq 1700
          expect(purchase.refunds.last.total_transaction_cents).to eq 1700
        end

        it "refunds the purchases corresponding to the Stripe charge in case of combined charge" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase,
                            price_cents: 1000,
                            total_transaction_cents: 1000,
                            is_part_of_combined_charge: true,
                            stripe_transaction_id: "ch_2Q7bRK9e1RjUNIyY1SMUhNqu")
          purchase_2 = create(:purchase,
                              price_cents: 700,
                              total_transaction_cents: 700,
                              is_part_of_combined_charge: true,
                              stripe_transaction_id: "ch_2Q7bRK9e1RjUNIyY1SMUhNqu")
          charge = create(:charge, amount_cents: 1700, processor_transaction_id: "ch_2Q7bRK9e1RjUNIyY1SMUhNqu")
          charge.purchases << purchase
          charge.purchases << purchase_2
          expect_any_instance_of(Purchase).to receive(:handle_event_refund_updated!).and_call_original

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded_for_fraud).with(purchase.id)
             .and have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded_for_fraud).with(purchase_2.id)
             .and not_have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded)

          expect(purchase.reload.stripe_refunded?).to be true
          expect(purchase.refunds.count).to eq 1
          expect(purchase.refunds.last.amount_cents).to eq 1000
          expect(purchase.refunds.last.total_transaction_cents).to eq 1000
          expect(purchase_2.reload.stripe_refunded?).to be true
          expect(purchase_2.refunds.count).to eq 1
          expect(purchase_2.refunds.last.amount_cents).to eq 700
          expect(purchase_2.refunds.last.total_transaction_cents).to eq 700
        end

        it "updates the corresponding refund statuses if purchases are already refunded" do
          stripe_event["data"]["object"]["status"] = "cancelled"

          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase,
                            price_cents: 1700,
                            total_transaction_cents: 1700,
                            stripe_transaction_id: "ch_2Q7bRK9e1RjUNIyY1SMUhNqu")
          refund = create(:refund,
                          purchase:,
                          amount_cents: 1700,
                          total_transaction_cents: 1700,
                          processor_refund_id: "re_2Q7bRK9e1RjUNIyY1icyswlr",
                          status: "succeeded")
          expect_any_instance_of(Purchase).to receive(:handle_event_refund_updated!).and_call_original

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.to not_have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded_for_fraud)
             .and not_have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded)

          expect(purchase.reload.refunds.count).to eq 1
          expect(purchase.refunds.last).to eq refund
          expect(refund.reload.status).to eq("cancelled")
        end

        it "does not refund the purchases if refund status is not succeeded" do
          stripe_event["data"]["object"]["status"] = "pending"

          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase,
                            price_cents: 1700,
                            total_transaction_cents: 1700,
                            stripe_transaction_id: "ch_2Q7bRK9e1RjUNIyY1SMUhNqu")
          expect_any_instance_of(Purchase).to receive(:handle_event_refund_updated!).and_call_original

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.to not_have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded_for_fraud)
             .and not_have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded)

          expect(purchase.reload.refunds.count).to eq 0
          expect(purchase.stripe_refunded?).to be false
        end
      end

      describe "event payment failed" do
        let(:stripe_event_type) { "payment_intent.payment_failed" }
        let(:purchase_external_id) { "q3jUBQrrGrIId3SjC4VJ0g==" }
        let(:stripe_event) do
          {
            "id" => "evt_2OQy7L9e1RjUNIyY0YbddRCB",
            "object" => "event",
            "account" => "9e1RjUNIyYGpA9Cfh3RmQxxTzb1aakpE",
            "api_version" => "2023-10-16",
            "created" => 1703449607,
            "data" => {
              "object" => {
                "id" => "pi_2OQy7L9e1RjUNIyY0PTiBSqm",
                "object" => "payment_intent",
                "amount" => 1705,
                "amount_capturable" => 0,
                "amount_details" => {
                  "tip" => {}
                },
                "amount_received" => 0,
                "application" => nil,
                "application_fee_amount" => nil,
                "automatic_payment_methods" => nil,
                "canceled_at" => nil,
                "cancellation_reason" => nil,
                "capture_method" => "automatic",
                "client_secret" => nil,
                "confirmation_method" => "automatic",
                "created" => 1703449067,
                "currency" => "usd",
                "customer" => "cus_PFSwikstjPi1vo",
                "description" => "You bought https://5557127576064.gumroad.dev/l/mb",
                "invoice" => nil,
                "last_payment_error" => {
                  "code" => "card_declined",
                  "decline_code" => "debit_notification_undelivered",
                  "doc_url" => "https://stripe.com/docs/error-codes/card-declined",
                  "message" => "The customer's bank could not send pre-debit notification for the payment.",
                  "payment_method" => {
                    "id" => "pm_0OQy0k9e1RjUNIyYee658LZl",
                    "object" => "payment_method",
                    "billing_details" => {
                      "address" => {
                        "city" => nil,
                        "country" => nil,
                        "line1" => nil,
                        "line2" => nil,
                        "postal_code" => "",
                        "state" => nil
                      },
                      "email" => nil,
                      "name" => nil,
                      "phone" => nil
                    },
                    "card" => {
                      "brand" => "visa",
                      "checks" => {
                        "address_line1_check" => nil,
                        "address_postal_code_check" => nil,
                        "cvc_check" => "pass"
                      },
                      "country" => Compliance::Countries::IND.alpha2,
                      "exp_month" => 12,
                      "exp_year" => 2032,
                      "fingerprint" => "CSyjVRpzVOm0p7hL",
                      "funding" => "credit",
                      "generated_from" => nil,
                      "last4" => "0248",
                      "networks" => {
                        "available" => [
                          "visa"
                        ],
                        "preferred" => nil
                      },
                      "three_d_secure_usage" => {
                        "supported" => true
                      },
                      "wallet" => nil
                    },
                    "created" => 1703448658,
                    "customer" => "cus_PFSwikstjPi1vo",
                    "livemode" => false,
                    "metadata" => {},
                    "type" => "card"
                  },
                  "type" => "card_error"
                },
                "latest_charge" => nil,
                "livemode" => false,
                "metadata" => {
                  "purchase" => "q3jUBQrrGrIId3SjC4VJ0g=="
                },
                "next_action" => nil,
                "on_behalf_of" => nil,
                "payment_method" => nil,
                "payment_method_configuration_details" => nil,
                "payment_method_options" => {
                  "card" => {
                    "installments" => nil,
                    "mandate_options" => nil,
                    "network" => nil,
                    "request_three_d_secure" => "automatic"
                  }
                },
                "payment_method_types" => [
                  "card"
                ],
                "processing" => nil,
                "receipt_email" => nil,
                "review" => nil,
                "setup_future_usage" => nil,
                "shipping" => nil,
                "source" => nil,
                "statement_descriptor" => nil,
                "statement_descriptor_suffix" => "5557127576064",
                "status" => "requires_payment_method",
                "transfer_data" => {
                  "amount" => 1455,
                  "destination" => "acct_1MltEr2mZ9S5oOnc"
                },
                "transfer_group" => "1215"
              }
            },
            "livemode" => false,
            "pending_webhooks" => 2,
            "request" => {
              "id" => nil,
              "idempotency_key" => nil
            },
            "type" => "payment_intent.payment_failed"
          }
        end

        it "works as only informational event if corresponding purchase is not on an Indian card" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase, id: ObfuscateIds.decrypt(purchase_external_id))
          expect_any_instance_of(Purchase).to receive(:handle_event_failed!).and_call_original
          expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
          expect_any_instance_of(Purchase).not_to receive(:mark_failed!)
          allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(purchase)

          StripeChargeProcessor.handle_stripe_event(stripe_event)
        end

        it "works as only informational event if corresponding purchase is not an off-session purchase" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          purchase = create(:purchase, id: ObfuscateIds.decrypt(purchase_external_id), card_country: Compliance::Countries::IND.alpha2)
          expect_any_instance_of(Purchase).to receive(:handle_event_failed!).and_call_original
          expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
          expect_any_instance_of(Purchase).not_to receive(:mark_failed!)
          allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(purchase)

          StripeChargeProcessor.handle_stripe_event(stripe_event)
        end

        it "marks the corresponding purchase failed if it's in progress for an off-session charge on an Indian card" do
          expect(ChargeProcessor).to(receive(:handle_event)).with(an_instance_of(ChargeEvent)).and_call_original

          subscription = create(:subscription)
          create(:purchase, subscription:, is_original_subscription_purchase: true)
          allow_any_instance_of(Subscription).to receive(:terminate_by).and_return(1.month.from_now)
          recurring_membership_purchase = create(:purchase, purchase_state: "in_progress", id: ObfuscateIds.decrypt(purchase_external_id), card_country: "IN", subscription:)

          expect_any_instance_of(Purchase).to receive(:handle_event_failed!).and_call_original
          expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
          expect_any_instance_of(Purchase).to receive(:mark_failed!).and_call_original
          allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(recurring_membership_purchase)

          StripeChargeProcessor.handle_stripe_event(stripe_event)

          expect(recurring_membership_purchase.reload.failed?).to be true
        end
      end
    end

    describe "event object: dispute" do
      let(:stripe_charge_destination) { nil }
      let(:stripe_charge_application_fee) { nil }

      let(:stripe_charge) do
        stripe_charge = create_stripe_charge(
          StripePaymentMethodHelper.success_charge_disputed.to_stripejs_payment_method_id,
          currency: "usd",
          amount: 10_00,
          transfer_data: { destination: stripe_charge_destination },
          on_behalf_of: stripe_charge_destination,
          application_fee_amount: stripe_charge_application_fee
        )
        stripe_charge.refresh
        while stripe_charge.dispute.nil?
          print "⟳"
          stripe_charge.refresh
        end
        stripe_charge
      end

      let(:stripe_dispute) { Stripe::Dispute.retrieve(id: stripe_charge.dispute) }
      let(:stripe_charge_id) { stripe_charge.id }
      let(:stripe_dispute_id) { stripe_dispute.id }
      let(:stripe_event_object) { stripe_dispute }

      describe "event dispute updated" do
        let(:stripe_event_type) { "charge.dispute.updated" }

        describe "for a charge on Gumroads account" do
          it "tells the charge processor about the informational event" do
            expect(ChargeProcessor).to receive(:handle_event).with(an_instance_of(ChargeEvent)).and_call_original
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end

        describe "for a charge on a managed account" do
          let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
          let(:stripe_charge_destination) { stripe_managed_account.id }

          it "tells the charge processor about the informational event" do
            expect(ChargeProcessor).to receive(:handle_event).with(an_instance_of(ChargeEvent)).and_call_original
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end
      end

      describe "event dispute created" do
        let(:stripe_event_type) { "charge.dispute.created" }

        describe "for a charge on Gumroads account" do
          it "tells the charge processor that a dispute was created" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_FORMALIZED)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              expect(charge_event.extras[:reason]).to eq("fraudulent")
              expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.issued_amount.cents).to eq(-1 * stripe_dispute.amount)
              expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.settled_amount.cents).to eq(-1 * stripe_dispute.amount)
              expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(-1 * stripe_dispute.amount)
              expect(charge_event.flow_of_funds.merchant_account_gross_amount).to eq(nil)
              expect(charge_event.flow_of_funds.merchant_account_net_amount).to eq(nil)
              original_handle_event.call(charge_event)
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end

        describe "for a charge on a managed account" do
          let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
          let(:stripe_charge_destination) { stripe_managed_account.id }

          it "tells the charge processor about the informational event" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_INFORMATIONAL)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              expect(charge_event.extras[:reason]).to eq("fraudulent")
              expect(charge_event.flow_of_funds).to eq(nil)
              original_handle_event.call(charge_event)
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end
      end

      describe "event dispute funds withdrawn" do
        let(:stripe_event_type) { "charge.dispute.funds_withdrawn" }

        describe "for a charge on Gumroads account" do
          it "tells the charge processor about the informational event" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_INFORMATIONAL)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              expect(charge_event.extras[:reason]).to eq("fraudulent")
              expect(charge_event.flow_of_funds).to eq(nil)
              original_handle_event.call(charge_event)
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end

        describe "for a charge on a managed account" do
          let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
          let(:stripe_charge_destination) { stripe_managed_account.id }
          let(:stripe_charge_application_fee) { 1_00 }

          it "reverses the transfer and refunds the application fee" do
            original_stripe_charge_retrieve = Stripe::Charge.method(:retrieve)
            allow(Stripe::Charge).to receive(:retrieve).and_call_original
            expect(Stripe::Charge).to receive(:retrieve).with(hash_including(id: stripe_charge_id)) do |*args|
              stripe_charge_retrieved = original_stripe_charge_retrieve.call(*args)
              expect(stripe_charge_retrieved.transfer.reversals).to receive(:create).with(hash_including(refund_application_fee: true)).and_call_original
              stripe_charge_retrieved
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end

          it "tells the charge processor that a dispute was created" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_FORMALIZED)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              expect(charge_event.extras[:reason]).to eq("fraudulent")

              # flow of funds issued amount
              expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.issued_amount.cents).to eq(-1 * stripe_dispute.amount)

              # flow of funds settled amount
              expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.balance_transactions.first.currency)
              expect(charge_event.flow_of_funds.settled_amount.cents).to eq(stripe_dispute.balance_transactions.first.amount)

              # flow of funds gumroad amount
              stripe_charge_application_fee = Stripe::ApplicationFee.retrieve(id: stripe_charge.application_fee, expand: %w[refunds.data.balance_transaction])
              expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_charge_application_fee.refunds.first.balance_transaction.currency)
              expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(stripe_charge_application_fee.refunds.first.balance_transaction.amount)

              # flow of funds merchant account amount
              stripe_charge_transfer = Stripe::Transfer.retrieve(id: stripe_charge.transfer)
              stripe_destination_payment = Stripe::Charge
                .retrieve({ id: stripe_charge_transfer.destination_payment,
                            expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                          { stripe_account: stripe_charge_transfer.destination })
              stripe_destination_payment_bt = stripe_destination_payment.refunds.first.balance_transaction

              expect(charge_event.flow_of_funds.merchant_account_gross_amount.currency).to eq(stripe_destination_payment_bt.currency)
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.cents).to eq(stripe_destination_payment_bt.amount)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.currency).to eq(stripe_destination_payment_bt.currency)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.cents).to eq(stripe_destination_payment_bt.amount + stripe_destination_payment.application_fee.refunds.first.amount)

              original_handle_event.call(charge_event)
            end)
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end

          describe "replaying the event" do
            before do
              StripeChargeProcessor.handle_stripe_event(stripe_event)
            end

            it "does not reverse the transfer or refund the application fee" do
              original_stripe_charge_retrieve = Stripe::Charge.method(:retrieve)
              allow(Stripe::Charge).to receive(:retrieve).and_call_original
              expect(Stripe::Charge).to receive(:retrieve).with(hash_including(id: stripe_charge_id)) do |*args|
                stripe_charge_retrieved = original_stripe_charge_retrieve.call(*args)
                expect(stripe_charge_retrieved.transfer.reversals).not_to receive(:create)
                stripe_charge_retrieved
              end
              StripeChargeProcessor.handle_stripe_event(stripe_event)
            end

            it "tells the charge processor that a dispute was created" do
              original_handle_event = ChargeProcessor.method(:handle_event)
              expect(ChargeProcessor).to(receive(:handle_event) do |charge_event|
                expect(charge_event).to be_a(ChargeEvent)
                expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_FORMALIZED)
                expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                expect(charge_event.extras[:reason]).to eq("fraudulent")

                # flow of funds issued amount
                expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
                expect(charge_event.flow_of_funds.issued_amount.cents).to eq(-1 * stripe_dispute.amount)

                # flow of funds settled amount
                expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.balance_transactions.first.currency)
                expect(charge_event.flow_of_funds.settled_amount.cents).to eq(stripe_dispute.balance_transactions.first.amount)

                # flow of funds gumroad amount
                stripe_charge_application_fee = Stripe::ApplicationFee.retrieve(id: stripe_charge.application_fee, expand: %w[refunds.data.balance_transaction])
                expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_charge_application_fee.refunds.first.balance_transaction.currency)
                expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(stripe_charge_application_fee.refunds.first.balance_transaction.amount)

                # flow of funds merchant account amount
                stripe_charge_transfer = Stripe::Transfer.retrieve(id: stripe_charge.transfer)
                stripe_destination_payment = Stripe::Charge.retrieve({ id: stripe_charge_transfer.destination_payment, expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                                     { stripe_account: stripe_charge_transfer.destination })

                stripe_destination_payment_bt = stripe_destination_payment.refunds.first.balance_transaction

                expect(charge_event.flow_of_funds.merchant_account_gross_amount.currency).to eq(stripe_destination_payment_bt.currency)
                expect(charge_event.flow_of_funds.merchant_account_gross_amount.cents).to eq(stripe_destination_payment_bt.amount)
                expect(charge_event.flow_of_funds.merchant_account_net_amount.currency).to eq(stripe_destination_payment_bt.currency)
                expect(charge_event.flow_of_funds.merchant_account_net_amount.cents).to eq(stripe_destination_payment_bt.amount + stripe_destination_payment.application_fee.refunds.first.amount)

                original_handle_event.call(charge_event)
              end)
              StripeChargeProcessor.handle_stripe_event(stripe_event)
            end
          end
        end

        describe "for a charge on managed account without on_behalf_of and application_fee_amount parameters" do
          let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
          let(:stripe_charge_destination) { stripe_managed_account.id }

          let(:stripe_charge) do
            stripe_charge = create_stripe_charge(
              StripePaymentMethodHelper.success_charge_disputed.to_stripejs_payment_method_id,
              currency: "usd",
              amount: 10_00,
              transfer_data: { destination: stripe_charge_destination, amount: 9_00 },
              )
            stripe_charge.refresh
            while stripe_charge.dispute.nil?
              print "⟳"
              stripe_charge.refresh
            end
            stripe_charge
          end

          it "reverses the transfer and refunds the application fee" do
            original_stripe_charge_retrieve = Stripe::Charge.method(:retrieve)
            allow(Stripe::Charge).to receive(:retrieve).and_call_original
            expect(Stripe::Charge).to receive(:retrieve).with(hash_including(id: stripe_charge_id)) do |*args|
              stripe_charge_retrieved = original_stripe_charge_retrieve.call(*args)
              expect(stripe_charge_retrieved.transfer.reversals).to receive(:create).with(hash_including(refund_application_fee: true)).and_call_original
              stripe_charge_retrieved
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end

          it "tells the charge processor that a dispute was created" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_FORMALIZED)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              expect(charge_event.extras[:reason]).to eq("fraudulent")

              # flow of funds issued amount
              expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.issued_amount.cents).to eq(-1 * stripe_dispute.amount)

              # flow of funds settled amount
              expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.balance_transactions.first.currency)
              expect(charge_event.flow_of_funds.settled_amount.cents).to eq(stripe_dispute.balance_transactions.first.amount)

              stripe_charge_transfer = Stripe::Transfer.retrieve(id: stripe_charge.transfer)
              stripe_destination_payment = Stripe::Charge
                                             .retrieve({ id: stripe_charge_transfer.destination_payment,
                                                         expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                       { stripe_account: stripe_charge_transfer.destination })
              stripe_destination_payment_bt = stripe_destination_payment.refunds.first.balance_transaction

              # flow of funds gumroad amount
              expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_charge.currency)
              expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(-1 * (stripe_charge.amount - stripe_charge_transfer.amount))

              # flow of funds merchant account amount
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.currency).to eq(stripe_destination_payment_bt.currency)
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.cents).to eq(stripe_destination_payment_bt.amount)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.currency).to eq(stripe_destination_payment_bt.currency)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.cents).to eq(stripe_destination_payment_bt.net)

              original_handle_event.call(charge_event)
            end)
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end
      end

      describe "event dispute funds reinstated" do
        let(:stripe_event_type) { "charge.dispute.funds_reinstated" }

        before do
          Stripe::Dispute.update(stripe_dispute.id, { evidence: { uncategorized_text: "winning_evidence" } })
          stripe_dispute.refresh
          while stripe_dispute.status != "won"
            print "⟳"
            stripe_dispute.refresh
          end
          stripe_charge.refresh
        end

        describe "for a charge on Gumroads account" do
          it "tells the charge processor about the informational event" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_INFORMATIONAL)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              expect(charge_event.flow_of_funds).to eq(nil)
              original_handle_event.call(charge_event)
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end

        describe "for a charge on a managed account" do
          let(:stripe_managed_account) do
            user = create(:user)
            create(:ach_account_stripe_succeed, user:)
            create(:merchant_account_stripe, user:)
          end
          let(:stripe_charge_destination) { stripe_managed_account.charge_processor_merchant_id }
          let(:stripe_charge_application_fee) { 1_00 }

          let(:stripe_charge_transfer_reversal) do
            stripe_charge_transfer = Stripe::Transfer.retrieve(stripe_charge.transfer)
            stripe_charge_transfer.reversals.first || stripe_charge_transfer.reversals.create(refund_application_fee: true, expand: %w[balance_transaction])
          end

          let(:stripe_charge_transfer_reversal_bt) do
            stripe_charge_transfer_reversal.balance_transaction
          end

          let(:purchase) do
            create(:purchase, total_transaction_cents: 10_00, stripe_transaction_id: stripe_charge.id)
          end

          before do
            stripe_charge_transfer_reversal
            stripe_charge.refresh
            purchase
          end

          it "creates a transfer for the funds" do
            expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
              message_why: "Dispute #{stripe_dispute_id} won",
              stripe_account_id: stripe_managed_account.charge_processor_merchant_id,
              currency: "usd",
              amount_cents: (purchase.total_transaction_cents - purchase.total_transaction_amount_for_gumroad_cents),
              related_charge_id: stripe_charge_id
            ).and_call_original
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end

          it "tells the charge processor that the dispute was won" do
            stripe_transfer = nil
            original_transfer_funds_to_account = StripeTransferInternallyToCreator.method(:transfer_funds_to_account)
            expect(StripeTransferInternallyToCreator).to(receive(:transfer_funds_to_account) do |*args, **kwargs|
              stripe_transfer = original_transfer_funds_to_account.call(*args, **kwargs)
            end)

            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_WON)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              # flow of funds issued amount
              expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.issued_amount.cents).to eq(stripe_dispute.amount)

              # flow of funds settled amount
              expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.balance_transactions.last.currency)
              expect(charge_event.flow_of_funds.settled_amount.cents).to eq(stripe_dispute.balance_transactions.last.amount)

              # flow of funds gumroad amount
              stripe_charge_application_fee = Stripe::ApplicationFee.retrieve(id: stripe_charge.application_fee, expand: %w[refunds.data.balance_transaction])
              expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_charge_application_fee.currency)
              expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(stripe_charge_application_fee.amount_refunded)

              # flow of funds merchant account amount
              stripe_destination_payment = Stripe::Charge.retrieve({ id: stripe_transfer.destination_payment, expand: %w[balance_transaction] }, { stripe_account: stripe_transfer.destination })
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.currency).to eq(stripe_destination_payment.balance_transaction.currency)
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.cents).to eq(stripe_destination_payment.balance_transaction.amount)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.currency).to eq(stripe_destination_payment.balance_transaction.currency)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.cents).to eq(stripe_destination_payment.balance_transaction.net)

              original_handle_event.call(charge_event)
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end

        describe "for a charge on a managed account without on_behalf_of and application_fee_amount parameters" do
          let(:stripe_charge) do
            stripe_payment_intent = create_stripe_payment_intent(
              StripePaymentMethodHelper.success_charge_disputed.to_stripejs_payment_method_id,
              currency: "usd",
              amount: 10_00,
              transfer_data: { destination: stripe_charge_destination, amount: 7_91 },
            )
            stripe_payment_intent.confirm
            stripe_charge = Stripe::Charge.retrieve(stripe_payment_intent.latest_charge)
            stripe_charge.refresh
            while stripe_charge.dispute.nil?
              print "⟳"
              stripe_charge.refresh
            end
            stripe_charge
          end

          let(:stripe_managed_account) do
            user = create(:user)
            create(:ach_account_stripe_succeed, user:)
            create(:merchant_account_stripe, user:)
          end
          let(:stripe_charge_destination) { stripe_managed_account.charge_processor_merchant_id }

          let(:stripe_charge_transfer) { Stripe::Transfer.retrieve(stripe_charge.transfer) }

          let(:stripe_charge_transfer_reversal) do
            stripe_charge_transfer = Stripe::Transfer.retrieve(stripe_charge.transfer)
            stripe_charge_transfer.reversals.first || stripe_charge_transfer.reversals.create(refund_application_fee: true, expand: %w[balance_transaction])
          end

          let(:stripe_charge_transfer_reversal_bt) do
            stripe_charge_transfer_reversal.balance_transaction
          end

          let(:purchase) do
            create(:purchase, price_cents: 10_00, total_transaction_cents: 10_00, stripe_transaction_id: stripe_charge.id)
          end

          before do
            stripe_charge_transfer_reversal
            stripe_charge.refresh
            purchase
          end

          it "creates a transfer for the funds" do
            expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
              message_why: "Dispute #{stripe_dispute_id} won",
              stripe_account_id: stripe_managed_account.charge_processor_merchant_id,
              currency: "usd",
              amount_cents: (purchase.total_transaction_cents - purchase.total_transaction_amount_for_gumroad_cents),
              related_charge_id: stripe_charge_id
            ).and_call_original
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end

          it "tells the charge processor that the dispute was won" do
            stripe_transfer = nil
            original_transfer_funds_to_account = StripeTransferInternallyToCreator.method(:transfer_funds_to_account)
            expect(StripeTransferInternallyToCreator).to(receive(:transfer_funds_to_account) do |*args, **kwargs|
              stripe_transfer = original_transfer_funds_to_account.call(*args, **kwargs)
            end)

            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_WON)
              expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
              # flow of funds issued amount
              expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
              expect(charge_event.flow_of_funds.issued_amount.cents).to eq(stripe_dispute.amount)

              # flow of funds settled amount
              expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.balance_transactions.last.currency)
              expect(charge_event.flow_of_funds.settled_amount.cents).to eq(stripe_dispute.balance_transactions.last.amount)

              # flow of funds gumroad amount
              expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_charge.currency)
              expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(stripe_charge.amount - stripe_charge_transfer.amount) # $1.59 (gumroad fee of 12.9% +30c)

              # flow of funds merchant account amount
              stripe_destination_payment = Stripe::Charge.retrieve({ id: stripe_transfer.destination_payment, expand: %w[balance_transaction] }, { stripe_account: stripe_transfer.destination })
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.currency).to eq(stripe_destination_payment.balance_transaction.currency)
              expect(charge_event.flow_of_funds.merchant_account_gross_amount.cents).to eq(stripe_destination_payment.balance_transaction.amount)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.currency).to eq(stripe_destination_payment.balance_transaction.currency)
              expect(charge_event.flow_of_funds.merchant_account_net_amount.cents).to eq(stripe_destination_payment.balance_transaction.net)

              original_handle_event.call(charge_event)
            end
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end
        end
      end

      describe "event dispute closed" do
        let(:stripe_event_type) { "charge.dispute.closed" }

        describe "in our favor" do
          describe "status 'won'" do
            before do
              Stripe::Dispute.update(stripe_dispute.id, { evidence: { uncategorized_text: "winning_evidence" } })
              stripe_dispute.refresh
              while stripe_dispute.status != "won"
                print "⟳"
                stripe_dispute.refresh
              end
              stripe_charge.refresh
            end

            describe "for a charge on Gumroads account" do
              it "tells the charge processor that the dispute was won" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
                  expect(charge_event).to be_a(ChargeEvent)
                  expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_WON)
                  expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                  expect(charge_event.flow_of_funds.issued_amount.currency).to eq(stripe_dispute.currency)
                  expect(charge_event.flow_of_funds.issued_amount.cents).to eq(stripe_dispute.amount)
                  expect(charge_event.flow_of_funds.settled_amount.currency).to eq(stripe_dispute.currency)
                  expect(charge_event.flow_of_funds.settled_amount.cents).to eq(stripe_dispute.amount)
                  expect(charge_event.flow_of_funds.gumroad_amount.currency).to eq(stripe_dispute.currency)
                  expect(charge_event.flow_of_funds.gumroad_amount.cents).to eq(stripe_dispute.amount)
                  expect(charge_event.flow_of_funds.merchant_account_gross_amount).to eq(nil)
                  expect(charge_event.flow_of_funds.merchant_account_net_amount).to eq(nil)
                  original_handle_event.call(charge_event)
                end
                StripeChargeProcessor.handle_stripe_event(stripe_event)
              end
            end

            describe "for a charge on a managed account" do
              let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
              let(:stripe_charge_destination) { stripe_managed_account.id }
              let(:stripe_charge_application_fee) { 1_00 }

              it "tells the charge processor about the informational event" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
                  expect(charge_event).to be_a(ChargeEvent)
                  expect(charge_event.type).to eq(ChargeEvent::TYPE_INFORMATIONAL)
                  expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                  expect(charge_event.flow_of_funds).to eq(nil)
                  original_handle_event.call(charge_event)
                end
                StripeChargeProcessor.handle_stripe_event(stripe_event)
              end
            end
          end

          describe "status 'warning_closed'" do
            before do
              Stripe::Dispute.update(stripe_dispute.id, { evidence: { uncategorized_text: "winning_evidence" } })
              stripe_dispute.refresh
              while stripe_dispute.status != "won"
                print "⟳"
                stripe_dispute.refresh
              end
              stripe_charge.refresh
              allow_any_instance_of(Stripe::Dispute).to receive(:status).and_return("warning_closed")
            end

            describe "for a charge on Gumroads account" do
              it "tells the charge processor that hte dispute was won" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
                  expect(charge_event).to be_a(ChargeEvent)
                  expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_WON)
                  expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                  original_handle_event.call(charge_event)
                end
                StripeChargeProcessor.handle_stripe_event(stripe_event)
              end
            end

            describe "for a charge on a managed account" do
              let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
              let(:stripe_charge_destination) { stripe_managed_account.id }
              let(:stripe_charge_application_fee) { 1_00 }

              it "tells the charge processor about the informational event" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
                  expect(charge_event).to be_a(ChargeEvent)
                  expect(charge_event.type).to eq(ChargeEvent::TYPE_INFORMATIONAL)
                  expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                  expect(charge_event.flow_of_funds).to eq(nil)
                  original_handle_event.call(charge_event)
                end
                StripeChargeProcessor.handle_stripe_event(stripe_event)
              end
            end
          end
        end

        describe "NOT in our favor" do
          describe "status 'lost'" do
            before do
              Stripe::Dispute.update(stripe_dispute.id, { evidence: { uncategorized_text: "losing_evidence" } })
              stripe_dispute.refresh
              while stripe_dispute.status != "lost"
                print "⟳"
                stripe_dispute.refresh
              end
              stripe_charge.refresh
            end

            describe "for a charge on Gumroads account" do
              before do
                allow(stripe_charge).to receive(:transfer_data).and_return(nil)
              end

              it "tells the charge processor the dispute was lost" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
                  expect(charge_event).to be_a(ChargeEvent)
                  expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_LOST)
                  expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                  expect(charge_event.flow_of_funds).to eq(nil)
                  original_handle_event.call(charge_event)
                end
                StripeChargeProcessor.handle_stripe_event(stripe_event)
              end
            end

            describe "for a charge on a managed account" do
              let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: Currency::CAD) }
              let(:stripe_charge_destination) { stripe_managed_account.id }
              let(:stripe_charge_application_fee) { 1_00 }

              it "tells the charge processor the dispute was lost" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event)) do |charge_event|
                  expect(charge_event).to be_a(ChargeEvent)
                  expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_LOST)
                  expect(charge_event.extras[:charge_processor_dispute_id]).to eq(stripe_dispute.id)
                  expect(charge_event.flow_of_funds).to eq(nil)
                  original_handle_event.call(charge_event)
                end
                StripeChargeProcessor.handle_stripe_event(stripe_event)
              end
            end
          end
        end
      end

      describe "event charge without charge id" do
        let(:stripe_event_type) { "charge.created" }
        let(:stripe_event_object) { { "object" => "charge" } }

        it "calls charge processors handle event with correct event info" do
          expect(ChargeProcessor).to_not(receive(:handle_event))
          expect { StripeChargeProcessor.handle_stripe_event(stripe_event) }.to raise_error(RuntimeError)
        end
      end

      describe "event dispute without charge id" do
        let(:stripe_event_type) { "charge.dispute.created" }
        let(:stripe_event_object) { { "object" => "dispute", "status" => "lost" } }

        it "calls charge processors handle event with correct event info" do
          expect(ChargeProcessor).to_not(receive(:handle_event))
          expect { StripeChargeProcessor.handle_stripe_event(stripe_event) }.to raise_error(RuntimeError)
        end
      end

      describe "event distpute without created at" do
        let(:stripe_event) do
          {
            "id" => stripe_event_id,
            "type" => "charge.created",
            "data" => {
              "object" => {
                "object" => "dispute",
                "charge" => stripe_charge_id,
                "status" => "lost"
              }
            }
          }
        end

        it "calls charge processors handle event with correct event info" do
          expect(ChargeProcessor).to_not(receive(:handle_event))
          expect { StripeChargeProcessor.handle_stripe_event(stripe_event) }.to raise_error(RuntimeError)
        end
      end
    end

    describe "event object: radar.early_fraud_warning.created" do
      let(:stripe_event) do
        {
          "id" => "evt_0O3PbG9e1RjUNIyYItGXQT4B",
          "object" => "event",
          "api_version" => "2020-08-27",
          "created" => 1697834837,
          "data" => {
            "object" => {
              "id" => "issfr_0O3PbF9e1RjUNIyYjsCznU4B",
              "object" => "radar.early_fraud_warning",
              "actionable" => true,
              "charge" => "ch_2O3PbE9e1RjUNIyY0ebHhJhd",
              "created" => 1697834837,
              "fraud_type" => "made_with_stolen_card",
              "livemode" => false,
              "payment_intent" => "pi_2O3PbE9e1RjUNIyY0KW85WwA"
            }
          },
          "livemode" => false,
          "pending_webhooks" => 4,
          "request" => {
            "id" => "req_TEsAQWMkc05z6a",
            "idempotency_key" => "551e860e-5ce1-44dc-9023-4343f8b4977e"
          },
          "type" => "radar.early_fraud_warning.created"
        }
      end

      it "calls StripeChargeRadarProcessor.handle_stripe_event" do
        expect(StripeChargeRadarProcessor).to receive(:handle_event).with(stripe_event)
        StripeChargeProcessor.handle_stripe_event(stripe_event)
      end
    end

    describe "event capital.financing_transaction.created" do
      let(:creator) { create(:user) }
      let!(:merchant_account) { create(:merchant_account_stripe, user: creator, charge_processor_merchant_id: "acct_1JrazyS8k6Whriun") }

      describe "automatic withholding" do
        let!(:purchase) { create(:purchase, link: create(:product, user: creator), stripe_transaction_id: "ch_2QbmSC9e1RjUNIyY0bwaBdlS") }
        let(:stripe_event_params) do
          {
            "id": "evt_0QbmSZ9e1RjUNIyYopDHaLso",
            "object": "event",
            "api_version": "2023-10-16; risk_in_requirements_beta=v1",
            "created": 1735578535,
            "data": {
              "object": {
                "id": "cptxn_1QbmSXS8k6WhriunIVbsV0S9",
                "object": "capital.financing_transaction",
                "account": "acct_1JrazyS8k6Whriun",
                "created_at": 1735578533,
                "details": {
                  "advance_amount": 14758,
                  "currency": "usd",
                  "fee_amount": 2656,
                  "linked_payment": "py_1QbmSES8k6WhriunD6ohMQaz",
                  "reason": "automatic_withholding",
                  "total_amount": 17414,
                  "transaction": {
                    "charge": "py_1QbmSES8k6WhriunD6ohMQaz"
                  }
                },
                "financing_offer": "financingoffer_0Pjsux9e1RjUNIyY0Ual3J91",
                "legacy_balance_transaction_source": "flxlnpd_1QbmSYS8k6Whriun0NGa5XKU",
                "livemode": true,
                "type": "payment",
                "user_facing_description": "Paydown of your loan"
              }
            },
            "livemode": true,
            "pending_webhooks": 1,
            "request": {
              "id": nil,
              "idempotency_key": nil
            },
            "type": "capital.financing_transaction.created"
          }
        end
        let!(:stripe_event) { Stripe::Util.convert_to_stripe_object(stripe_event_params, {}) }

        it "adds a negative credit if not already done for this paydown" do
          expect(Stripe::Charge).to receive(:retrieve).with("py_1QbmSES8k6WhriunD6ohMQaz", { stripe_account: "acct_1JrazyS8k6Whriun" }).and_return(double(source_transfer: "tr_1QbmSXS8k6WhriunIVbsV0S9"))
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_1QbmSXS8k6WhriunIVbsV0S9").and_return(double(source_transaction: "ch_2QbmSC9e1RjUNIyY0bwaBdlS"))

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.to change { Credit.count }.by(1)

          credit = Credit.last
          expect(credit.amount_cents).to eq(-17414)
          expect(credit.merchant_account).to eq(merchant_account)
          expect(credit.financing_paydown_purchase).to eq(purchase)
          expect(credit.stripe_loan_paydown_id).to eq("cptxn_1QbmSXS8k6WhriunIVbsV0S9")

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.not_to change { Credit.count }
        end

        it "does not add another negative credit if one is already added for this paydown" do
          create(:credit,
                 user: creator,
                 merchant_account: merchant_account,
                 financing_paydown_purchase: purchase,
                 stripe_loan_paydown_id: "cptxn_1QbmSXS8k6WhriunIVbsV0S9",
                 amount_cents: -17414)

          expect(Stripe::Charge).not_to receive(:retrieve)
          expect(Stripe::Transfer).not_to receive(:retrieve)

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.not_to change { Credit.count }
        end
      end

      describe "manual paydown" do
        let(:stripe_event_params) do
          {
            "id": "evt_0QYGAQ9e1RjUNIyYf54eCbYR",
            "object": "event",
            "api_version": "2023-10-16; risk_in_requirements_beta=v1",
            "created": 1734739418,
            "data": {
              "object": {
                "id": "cptxn_1QYGAMS8k6Whriun3Ks2V9XM",
                "object": "capital.financing_transaction",
                "account": "acct_1JrazyS8k6Whriun",
                "created_at": 1734739414,
                "details": {
                  "advance_amount": 186573,
                  "currency": "usd",
                  "fee_amount": 33583,
                  "reason": "collection",
                  "total_amount": 220156
                },
                "financing_offer": "financingoffer_0Pjsux9e1RjUNIyY0Ual3J91",
                "legacy_balance_transaction_source": "flxlnpd_1QYGAMS8k6WhriunjwlD8pdL",
                "livemode": true,
                "type": "payment",
                "user_facing_description": "Manual paydown of your loan"
              }
            },
            "livemode": true,
            "pending_webhooks": 1,
            "request": {
              "id": nil,
              "idempotency_key": nil
            },
            "type": "capital.financing_transaction.created"
          }
        end
        let!(:stripe_event) { Stripe::Util.convert_to_stripe_object(stripe_event_params, {}) }

        it "adds a negative credit if not already done for this paydown" do
          admin = create(:admin_user)
          stub_const("GUMROAD_ADMIN_ID", admin.id)

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.to change { Credit.count }.by(1)

          credit = Credit.last
          expect(credit.amount_cents).to eq(-220156)
          expect(credit.merchant_account).to eq(merchant_account)
          expect(credit.crediting_user).to eq(admin)
          expect(credit.stripe_loan_paydown_id).to eq("cptxn_1QYGAMS8k6Whriun3Ks2V9XM")

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.not_to change { Credit.count }
        end

        it "does not add another negative credit if one is already added for this paydown" do
          create(:credit,
                 user: creator,
                 merchant_account: merchant_account,
                 stripe_loan_paydown_id: "cptxn_1QYGAMS8k6Whriun3Ks2V9XM",
                 amount_cents: -220156)

          expect do
            StripeChargeProcessor.handle_stripe_event(stripe_event)
          end.not_to change { Credit.count }
        end
      end
    end
  end

  describe ".debit_stripe_account_for_refund_fee" do
    before do
      @merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_1MdawPS4gcql7bLm", country: "AE")
    end

    it "reverses an internal transfer made to the stripe connect account if present" do
      create(:payment_completed, user: @merchant_account.user,
                                 stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                 stripe_internal_transfer_id: nil)

      create(:payment_completed, user: @merchant_account.user,
                                 stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                 stripe_internal_transfer_id: "tr_2NJ2gI9e1RjUNIyY05mygCqr")

      credit = create(:credit, user: @merchant_account.user, amount_cents: 1000, merchant_account_id: @merchant_account.id, fee_retention_refund: create(:refund))

      expect_any_instance_of(Refund).to receive(:update!).with({ debited_stripe_transfer: anything })

      described_class.debit_stripe_account_for_refund_fee(credit:)
    end

    it "reverses the earliest sale transfer if no internal transfer is present" do
      travel_to(Time.zone.local(2023, 10, 6)) do
        credit = create(:credit, amount_cents: 1000, merchant_account_id: @merchant_account.id, fee_retention_refund: create(:refund))

        expect_any_instance_of(Refund).to receive(:update!).with({ debited_stripe_transfer: anything })

        described_class.debit_stripe_account_for_refund_fee(credit:)
      end
    end
  end

  describe ".debit_stripe_account_for_australia_backtaxes" do
    it "does not attempt a transfer if there are already backtax collection transfers for this agreement" do
      merchant_account = create(:merchant_account)
      backtax_agreement = create(:backtax_agreement, collected: true)
      credit = create(:credit, user: merchant_account.user, amount_cents: -1000, merchant_account_id: merchant_account.id, backtax_agreement:)

      expect do
        described_class.debit_stripe_account_for_australia_backtaxes(credit:)
      end.to_not change { BacktaxCollection.count }
    end

    describe "when merchant account is PayPal" do
      before do
        @merchant_account = create(:merchant_account_paypal, country: "VN")
      end

      it "creates a backtax collection with no stripe transfer id for the amount of the negative credit" do
        credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))

        expect do
          described_class.debit_stripe_account_for_australia_backtaxes(credit:)
        end.to change { BacktaxCollection.count }.by(1)

        backtax_collection = BacktaxCollection.last
        expect(backtax_collection.amount_cents).to eq(1000)
        expect(backtax_collection.amount_cents_usd).to eq(1000)
        expect(backtax_collection.currency).to eq("usd")
        expect(backtax_collection.stripe_transfer_id).to eq(nil)

        expect(credit.backtax_agreement.collected).to eq(true)
      end
    end

    describe "when merchant account is a creator's Gumroad-controlled Stripe account" do
      describe "when the merchant account is US" do
        before do
          @merchant_account = create(:merchant_account, country: "US")
          stripe_object_available_double = double(currency: "usd", amount: 900)
          stripe_object_pending_double = double(currency: "usd", amount: 600)
          @stripe_balance = double(available: [stripe_object_available_double], pending: [stripe_object_pending_double])
        end

        it "creates a debit transfer for the taxes owed amount" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123")
          expect(Stripe::Transfer).to receive(:create).with(hash_including({ amount: 1000, currency: "usd" }), hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(transfer)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(1)

          backtax_collection = BacktaxCollection.last
          expect(backtax_collection.amount_cents).to eq(1000)
          expect(backtax_collection.amount_cents_usd).to eq(1000)
          expect(backtax_collection.currency).to eq("usd")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_123")

          expect(credit.backtax_agreement.collected).to eq(true)
        end
      end

      describe "when the merchant account is non-US" do
        before do
          $currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
          $currency_namespace.set("CAD", 1.33)

          @merchant_account = create(:merchant_account, country: "CA", currency: "cad")
          stripe_object_available_double = double(currency: "cad", amount: 1000)
          stripe_object_pending_double = double(currency: "cad", amount: 995)
          @stripe_balance = double(available: [stripe_object_available_double], pending: [stripe_object_pending_double])
        end

        it "creates a reversal from a single past internal transfer" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123")

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 1330, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").and_return(transfer)

          transfer_reversal = double(id: "tr_456")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 1330 })).and_return(transfer_reversal)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(1)

          backtax_collection = BacktaxCollection.last
          expect(backtax_collection.amount_cents).to eq(1330)
          expect(backtax_collection.amount_cents_usd).to eq(1000)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_456")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "creates reversals for multiple past internal transfers" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123")
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_456")

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").ordered.and_return(transfer)
          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_456").ordered.and_return(transfer_2)

          transfer_reversal = double(id: "tr_567")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 1000 })).ordered.and_return(transfer_reversal)
          transfer_reversal_2 = double(id: "tr_890")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 330 })).ordered.and_return(transfer_reversal_2)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(2)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_567")
          expect(backtax_collection.amount_cents).to eq(1000)
          expect(backtax_collection.amount_cents_usd).to eq(752)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_567")
          backtax_collection_2 = BacktaxCollection.find_by_stripe_transfer_id("tr_890")
          expect(backtax_collection_2.amount_cents).to eq(330)
          expect(backtax_collection_2.amount_cents_usd).to eq(248)
          expect(backtax_collection_2.currency).to eq("cad")
          expect(backtax_collection_2.stripe_transfer_id).to eq("tr_890")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "creates reversals for multiple transfers associated with old purchases" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer, transfer_2])

          transfer_reversal = double(id: "tr_567")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 1000 })).ordered.and_return(transfer_reversal)
          transfer_reversal_2 = double(id: "tr_890")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 330 })).ordered.and_return(transfer_reversal_2)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(2)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_567")
          expect(backtax_collection.amount_cents).to eq(1000)
          expect(backtax_collection.amount_cents_usd).to eq(752)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_567")
          backtax_collection_2 = BacktaxCollection.find_by_stripe_transfer_id("tr_890")
          expect(backtax_collection_2.amount_cents).to eq(330)
          expect(backtax_collection_2.amount_cents_usd).to eq(248)
          expect(backtax_collection_2.currency).to eq("cad")
          expect(backtax_collection_2.stripe_transfer_id).to eq("tr_890")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "creates reversals for both past internal transfers and transfers associated with old purchases" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123")
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_456")

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 300, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").ordered.and_return(transfer)
          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_456").ordered.and_return(transfer_2)

          transfer = double(id: "tr_789", amount: 450, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_012", amount: 250, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer, transfer_2])

          transfer_reversal = double(id: "tr_345")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 300 })).ordered.and_return(transfer_reversal)
          transfer_reversal_2 = double(id: "tr_678")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 400 })).ordered.and_return(transfer_reversal_2)
          transfer_reversal_3 = double(id: "tr_901")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_789", hash_including({ amount: 450 })).ordered.and_return(transfer_reversal_3)
          transfer_reversal_4 = double(id: "tr_234")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_012", hash_including({ amount: 180 })).ordered.and_return(transfer_reversal_4)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(4)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_345")
          expect(backtax_collection.amount_cents).to eq(300)
          expect(backtax_collection.amount_cents_usd).to eq(226)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_345")
          backtax_collection_2 = BacktaxCollection.find_by_stripe_transfer_id("tr_678")
          expect(backtax_collection_2.amount_cents).to eq(400)
          expect(backtax_collection_2.amount_cents_usd).to eq(301)
          expect(backtax_collection_2.currency).to eq("cad")
          expect(backtax_collection_2.stripe_transfer_id).to eq("tr_678")
          backtax_collection_3 = BacktaxCollection.find_by_stripe_transfer_id("tr_901")
          expect(backtax_collection_3.amount_cents).to eq(450)
          expect(backtax_collection_3.amount_cents_usd).to eq(338)
          expect(backtax_collection_3.currency).to eq("cad")
          expect(backtax_collection_3.stripe_transfer_id).to eq("tr_901")
          backtax_collection_4 = BacktaxCollection.find_by_stripe_transfer_id("tr_234")
          expect(backtax_collection_4.amount_cents).to eq(180)
          expect(backtax_collection_4.amount_cents_usd).to eq(135)
          expect(backtax_collection_4.currency).to eq("cad")
          expect(backtax_collection_4.stripe_transfer_id).to eq("tr_234")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "does not create reversals if the accumlated sum of transfer amounts is not enough to cover the taxes owed" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123")
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_456")

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 100, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").ordered.and_return(transfer)
          transfer_2 = double(id: "tr_456", amount: 100, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_456").ordered.and_return(transfer_2)

          transfer = double(id: "tr_789", amount: 100, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_012", amount: 100, amount_reversed: 0, currency: "cad")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).ordered.and_return([transfer, transfer_2])
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).ordered.and_return([])

          expect(Stripe::Transfer).to_not receive(:create_reversal)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to_not change { BacktaxCollection.count }

          expect(credit.backtax_agreement.collected).to eq(false)
        end

        it "creates reversals in usd and skips reversals in cad when usd transfers cover the amount owed" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_456", amount: 200, amount_reversed: 0, currency: "cad")
          transfer_3 = double(id: "tr_789", amount: 900, amount_reversed: 0, currency: "usd")
          transfer_4 = double(id: "tr_012", amount: 200, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer, transfer_2, transfer_3, transfer_4])

          transfer_reversal = double(id: "tr_345")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_789", hash_including({ amount: 900 })).ordered.and_return(transfer_reversal)
          transfer_reversal_2 = double(id: "tr_678")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_012", hash_including({ amount: 100 })).ordered.and_return(transfer_reversal_2)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(2)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_345")
          expect(backtax_collection.amount_cents).to eq(900)
          expect(backtax_collection.amount_cents_usd).to eq(900)
          expect(backtax_collection.currency).to eq("usd")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_345")
          backtax_collection_2 = BacktaxCollection.find_by_stripe_transfer_id("tr_678")
          expect(backtax_collection_2.amount_cents).to eq(100)
          expect(backtax_collection_2.amount_cents_usd).to eq(100)
          expect(backtax_collection_2.currency).to eq("usd")
          expect(backtax_collection_2.stripe_transfer_id).to eq("tr_678")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "creates reversals in cad and skips reversals in usd when cad transfers cover the amount owed" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "cad")
          transfer_3 = double(id: "tr_789", amount: 500, amount_reversed: 0, currency: "usd")
          transfer_4 = double(id: "tr_012", amount: 200, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer, transfer_2, transfer_3, transfer_4])

          transfer_reversal = double(id: "tr_345")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 1000 })).ordered.and_return(transfer_reversal)
          transfer_reversal_2 = double(id: "tr_678")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 330 })).ordered.and_return(transfer_reversal_2)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(2)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_345")
          expect(backtax_collection.amount_cents).to eq(1000)
          expect(backtax_collection.amount_cents_usd).to eq(752)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_345")
          backtax_collection_2 = BacktaxCollection.find_by_stripe_transfer_id("tr_678")
          expect(backtax_collection_2.amount_cents).to eq(330)
          expect(backtax_collection_2.amount_cents_usd).to eq(248)
          expect(backtax_collection_2.currency).to eq("cad")
          expect(backtax_collection_2.stripe_transfer_id).to eq("tr_678")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "creates reversals covering the rest of the amount owed when only a partial amount has been transferred" do
          backtax_agreement = create(:backtax_agreement)
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement:)
          create(:backtax_collection, backtax_agreement:, amount_cents: 1000, amount_cents_usd: 751, currency: "cad", stripe_transfer_id: "tr_345")
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 400, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_456", amount: 500, amount_reversed: 0, currency: "usd")
          transfer_3 = double(id: "tr_789", amount: 200, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer, transfer_2, transfer_3])

          transfer_reversal = double(id: "tr_012")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 331 })).ordered.and_return(transfer_reversal)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(1)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_012")
          expect(backtax_collection.amount_cents).to eq(331)
          expect(backtax_collection.amount_cents_usd).to eq(249)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_012")

          expect(credit.backtax_agreement.collected).to eq(true)
        end

        it "creates reversals when it is necessary to list Stripe transfers more than once" do
          credit = create(:credit, user: @merchant_account.user, amount_cents: -1000, merchant_account_id: @merchant_account.id, backtax_agreement: create(:backtax_agreement))
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)

          expect(Stripe::Balance).to receive(:retrieve).with(hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(@stripe_balance)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "cad")
          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "cad")
          transfer_3 = double(id: "tr_789", amount: 500, amount_reversed: 0, currency: "usd")
          transfer_4 = double(id: "tr_012", amount: 200, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).ordered.and_return([transfer, transfer_3, transfer_4])
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).ordered.and_return([transfer_2])

          transfer_reversal = double(id: "tr_345")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 1000 })).ordered.and_return(transfer_reversal)
          transfer_reversal_2 = double(id: "tr_678")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 330 })).ordered.and_return(transfer_reversal_2)

          expect do
            described_class.debit_stripe_account_for_australia_backtaxes(credit:)
          end.to change { BacktaxCollection.count }.by(2)

          backtax_collection = BacktaxCollection.find_by_stripe_transfer_id("tr_345")
          expect(backtax_collection.amount_cents).to eq(1000)
          expect(backtax_collection.amount_cents_usd).to eq(752)
          expect(backtax_collection.currency).to eq("cad")
          expect(backtax_collection.stripe_transfer_id).to eq("tr_345")
          backtax_collection_2 = BacktaxCollection.find_by_stripe_transfer_id("tr_678")
          expect(backtax_collection_2.amount_cents).to eq(330)
          expect(backtax_collection_2.amount_cents_usd).to eq(248)
          expect(backtax_collection_2.currency).to eq("cad")
          expect(backtax_collection_2.stripe_transfer_id).to eq("tr_678")

          expect(credit.backtax_agreement.collected).to eq(true)
        end
      end
    end
  end
end
