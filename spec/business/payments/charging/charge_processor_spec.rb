# frozen_string_literal: true

require "spec_helper"

describe ChargeProcessor do
  describe ".get_chargeable_for_params" do
    it "calls get_chargeable_for_params on the charge processors" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:get_chargeable_for_params).with({ param: "param" }, nil)
      ChargeProcessor.get_chargeable_for_params({ param: "param" }, nil)
    end
  end

  describe ".get_chargeable_for_data", :vcr do
    it "calls get_chargeable_for_data on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:get_chargeable_for_data).with(
        "customer-id",
        "payment_method",
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
        nil,
        merchant_account: nil
      ).and_call_original
      ChargeProcessor.get_chargeable_for_data(
        {
          StripeChargeProcessor.charge_processor_id => "customer-id"
        },
        "payment_method",
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
    end

    it "calls get_chargeable_for_data on the correct charge processor with zip if provided" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:get_chargeable_for_data).with(
        "customer-id",
        "payment_method",
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
        "zip-code",
        merchant_account: nil
      ).and_call_original
      ChargeProcessor.get_chargeable_for_data(
        {
          StripeChargeProcessor.charge_processor_id => "customer-id"
        },
        "payment_method",
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
        "zip-code"
      )
    end
  end

  describe ".get_charge" do
    it "calls get_charge on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:get_charge).with("charge-id", merchant_account: nil)
      ChargeProcessor.get_charge(StripeChargeProcessor.charge_processor_id, "charge-id")
    end
  end

  describe ".create_payment_intent_or_charge!" do
    let(:merchant_account) { create(:merchant_account) }
    let(:stripe_chargeable) { double }
    let(:chargeable) do
      chargeable = double
      allow(chargeable).to receive(:get_chargeable_for).and_return(stripe_chargeable)
      chargeable
    end

    it "calls create_payment_intent_or_charge! on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
        merchant_account,
        stripe_chargeable,
        1_00,
        0_30,
        "reference",
        "description",
        metadata: nil,
        statement_description: "statement-description",
        transfer_group: nil,
        off_session: true,
        setup_future_charges: true,
        mandate_options: nil
      )
      ChargeProcessor.create_payment_intent_or_charge!(
        merchant_account,
        chargeable,
        1_00,
        0_30,
        "reference",
        "description",
        statement_description: "statement-description",
        off_session: true,
        setup_future_charges: true
      )
    end

    it "passes mandate_options to create_payment_intent_or_charge! on the correct charge processor" do
      mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: {
              reference: StripeChargeProcessor::MANDATE_PREFIX + SecureRandom.hex,
              amount_type: "maximum",
              amount: 10_00,
              start_date: Time.current.to_i,
              interval: "month",
              interval_count: 1,
              supported_types: ["india"]
            }
          }
        }
      }

      expect_any_instance_of(StripeChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
        merchant_account,
        stripe_chargeable,
        1_00,
        0_30,
        "reference",
        "description",
        metadata: nil,
        statement_description: "statement-description",
        transfer_group: nil,
        off_session: true,
        setup_future_charges: true,
        mandate_options:
      )

      ChargeProcessor.create_payment_intent_or_charge!(
        merchant_account,
        chargeable,
        1_00,
        0_30,
        "reference",
        "description",
        metadata: nil,
        statement_description: "statement-description",
        off_session: true,
        setup_future_charges: true,
        mandate_options:
      )
    end
  end

  describe ".get_charge_intent" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:charge_intent_id) { "pi_123456" }

    it "returns nil if blank charge intent ID is passed" do
      expect_any_instance_of(StripeChargeProcessor).not_to receive(:get_charge_intent)
      charge_intent = ChargeProcessor.get_charge_intent(merchant_account, nil)
      expect(charge_intent).to be_nil
    end

    it "calls get_charge_intent on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:get_charge_intent).with(charge_intent_id, merchant_account:)
      ChargeProcessor.get_charge_intent(merchant_account, charge_intent_id)
    end
  end

  describe ".get_setup_intent" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:setup_intent_id) { "seti_123456" }

    it "returns nil if blank setup intent ID is passed" do
      expect_any_instance_of(StripeChargeProcessor).not_to receive(:get_setup_intent)
      setup_intent = ChargeProcessor.get_setup_intent(merchant_account, nil)
      expect(setup_intent).to be_nil
    end

    it "calls get_charge_intent on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:get_setup_intent).with(setup_intent_id, merchant_account:)
      ChargeProcessor.get_setup_intent(merchant_account, setup_intent_id)
    end
  end

  describe ".confirm_payment_intent!" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:charge_intent_id) { "pi_123456" }

    it "calls confirm_payment_intent! on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:confirm_payment_intent!).with(
        merchant_account,
        charge_intent_id
      )
      ChargeProcessor.confirm_payment_intent!(merchant_account, charge_intent_id)
    end
  end

  describe ".cancel_payment_intent!" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:charge_intent_id) { "pi_123456" }

    it "calls cancel_payment_intent! on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:cancel_payment_intent!).with(merchant_account, charge_intent_id)
      ChargeProcessor.cancel_payment_intent!(merchant_account, charge_intent_id)
    end
  end

  describe ".cancel_setup_intent!" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:setup_intent_id) { "seti_123456" }

    it "calls cancel_setup_intent! on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:cancel_setup_intent!).with(merchant_account, setup_intent_id)
      ChargeProcessor.cancel_setup_intent!(merchant_account, setup_intent_id)
    end
  end

  describe ".setup_future_charges!" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:stripe_chargeable) { double }
    let(:chargeable) { double }

    before do
      allow(chargeable).to receive(:get_chargeable_for).and_return(stripe_chargeable)
    end

    it "calls setup_future_charges! on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:setup_future_charges!).with(merchant_account, stripe_chargeable, mandate_options: nil)
      ChargeProcessor.setup_future_charges!(merchant_account, chargeable)
    end

    it "passes mandate_options parameter to setup_future_charges! on the correct charge processor" do
      mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: {
              reference: StripeChargeProcessor::MANDATE_PREFIX + SecureRandom.hex,
              amount_type: "maximum",
              amount: 10_00,
              start_date: Time.current.to_i,
              interval: "month",
              interval_count: 1,
              supported_types: ["india"]
            }
          }
        }
      }

      expect_any_instance_of(StripeChargeProcessor).to receive(:setup_future_charges!).with(merchant_account, stripe_chargeable, mandate_options:)
      ChargeProcessor.setup_future_charges!(merchant_account, chargeable, mandate_options:)
    end
  end

  describe ".refund!" do
    describe "full refund" do
      it "calls get_charge on the correct charge processor" do
        expect_any_instance_of(StripeChargeProcessor).to receive(:refund!).with("charge-id", amount_cents: nil,
                                                                                             merchant_account: nil,
                                                                                             paypal_order_purchase_unit_refund: nil,
                                                                                             reverse_transfer: true,
                                                                                             is_for_fraud: nil)
        ChargeProcessor.refund!(StripeChargeProcessor.charge_processor_id, "charge-id",)
      end
    end

    describe "partial refund" do
      it "calls get_charge on the correct charge processor" do
        expect_any_instance_of(StripeChargeProcessor).to receive(:refund!).with("charge-id", amount_cents: 2_00,
                                                                                             merchant_account: nil,
                                                                                             paypal_order_purchase_unit_refund: nil,
                                                                                             reverse_transfer: true,
                                                                                             is_for_fraud: nil)
        ChargeProcessor.refund!(StripeChargeProcessor.charge_processor_id, "charge-id", amount_cents: 2_00)
      end
    end
  end

  describe ".holder_of_funds" do
    let(:merchant_account) { create(:merchant_account) }

    it "calls holder_of_funds on the correct charge processor" do
      expect_any_instance_of(StripeChargeProcessor).to receive(:holder_of_funds).with(merchant_account)
      ChargeProcessor.holder_of_funds(merchant_account)
    end
  end

  describe ".handle_event" do
    let(:charge_event) { build(:charge_event_informational) }

    before do
      @subscriber = ActiveSupport::Notifications.subscribe(ChargeProcessor::NOTIFICATION_CHARGE_EVENT) do |_, _, _, _, payload|
        expect(payload).to include(charge_event:)
      end
    end

    after do
      ActiveSupport::Notifications.unsubscribe(@subscriber)
    end

    it "posts a charge event to active support notifications" do
      ChargeProcessor.handle_event(charge_event)
    end
  end

  describe ".transaction_url" do
    describe "in a non-production environment" do
      it "returns a valid url for all charge processors" do
        described_class.charge_processor_ids.each do |charge_processor_id|
          transaction_url = ChargeProcessor.transaction_url(charge_processor_id, "dummy_charge_id")
          expect(transaction_url).to be_a(String)
          expect(URI.parse(transaction_url)).to be_a(URI)
        end
      end
    end

    describe "in a production environment" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      it "returns a valid url for all charge processors" do
        described_class.charge_processor_ids.each do |charge_processor_id|
          transaction_url = ChargeProcessor.transaction_url(charge_processor_id, "dummy_charge_id")
          expect(transaction_url).to be_a(String)
          expect(URI.parse(transaction_url)).to be_a(URI)
        end
      end
    end
  end

  describe ".transaction_url_for_seller" do
    let(:charge_processor_id) { StripeChargeProcessor.charge_processor_id }
    let(:charge_id) { "dummy_charge_id" }

    it "returns nil if charge_processor_id is nil" do
      url = ChargeProcessor.transaction_url_for_seller(nil, charge_id, false)
      expect(url).to be(nil)
    end

    it "returns nil if charge_id is nil" do
      url = ChargeProcessor.transaction_url_for_seller(charge_processor_id, nil, false)
      expect(url).to be(nil)
    end

    it "returns nil if charged_using_gumroad_account" do
      url = ChargeProcessor.transaction_url_for_seller(charge_processor_id, charge_id, true)
      expect(url).to be(nil)
    end

    it "returns url if not charged_using_gumroad_account" do
      url = ChargeProcessor.transaction_url_for_seller(charge_processor_id, charge_id, false)
      expect(URI.parse(url)).to be_a(URI)
    end
  end

  describe ".transaction_url_for_admin" do
    let(:charge_processor_id) { StripeChargeProcessor.charge_processor_id }
    let(:charge_id) { "dummy_charge_id" }

    it "returns nil if charge_processor_id is nil" do
      url = ChargeProcessor.transaction_url_for_admin(nil, charge_id, false)
      expect(url).to be(nil)
    end

    it "returns nil if charge_id is nil" do
      url = ChargeProcessor.transaction_url_for_admin(charge_processor_id, nil, false)
      expect(url).to be(nil)
    end

    it "returns nil if not charged_using_gumroad_account" do
      url = ChargeProcessor.transaction_url_for_admin(charge_processor_id, charge_id, false)
      expect(url).to be(nil)
    end

    it "returns url if charged_using_gumroad_account" do
      url = ChargeProcessor.transaction_url_for_admin(charge_processor_id, charge_id, true)
      expect(URI.parse(url)).to be_a(URI)
    end
  end
end
