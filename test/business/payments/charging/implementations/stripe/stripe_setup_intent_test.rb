# frozen_string_literal: true

require "test_helper"

class StripeSetupIntentTest < ActiveSupport::TestCase
  self.described_class = StripeSetupIntent
  self.rspec_metadata = { vcr: true }



  context_ StripeSetupIntent, :vcr do
    include StripeChargesHelper

    let(:processor_setup_intent) { create_stripe_setup_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id) }

    subject (:stripe_setup_intent) { described_class.new(processor_setup_intent) }

  context_ "#id" do
  test "returns the ID of Stripe setup intent" do
        expect(stripe_setup_intent.id).to eq(processor_setup_intent.id)
      end
    end

  context_ "#client_secret" do
  test "returns the client secret of Stripe setup intent" do
        expect(stripe_setup_intent.client_secret).to eq(processor_setup_intent.client_secret)
      end
    end

  context_ "when Stripe setup intent is successful" do
      let(:processor_setup_intent) do
        create_stripe_setup_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id)
      end

  test "is successful" do
        expect(stripe_setup_intent.succeeded?).to eq(true)
      end

  test "does not require action" do
        expect(stripe_setup_intent.requires_action?).to eq(false)
      end
    end

  context_ "when Stripe payment intent is not successful" do
      let(:processor_setup_intent) do
        create_stripe_setup_intent(nil, confirm: false)
      end

  test "is not successful" do
        expect(stripe_setup_intent.succeeded?).to eq(false)
      end

  test "does not require action" do
        expect(stripe_setup_intent.requires_action?).to eq(false)
      end
    end

  context_ "when Stripe payment intent is canceled" do
      let(:processor_setup_intent) do
        setup_intent = create_stripe_setup_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id, confirm: false)
        ChargeProcessor.cancel_setup_intent!(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), setup_intent.id)
      end

  test "is canceled" do
        expect(stripe_setup_intent.canceled?).to eq(true)
      end

  test "is not successful" do
        expect(stripe_setup_intent.succeeded?).to eq(false)
      end

  test "does not require action" do
        expect(stripe_setup_intent.requires_action?).to eq(false)
      end
    end

  context_ "when Stripe payment intent requires action" do
      let(:processor_setup_intent) do
        create_stripe_setup_intent(StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id)
      end

  test "is not successful" do
        expect(stripe_setup_intent.succeeded?).to eq(false)
      end

  test "requires action" do
        expect(stripe_setup_intent.requires_action?).to eq(true)
      end

  context_ "when next action type is unsupported" do
        before do
          allow(processor_setup_intent.next_action).to receive(:type).and_return "redirect_to_url"
        end

  test "notifies error tracker" do
          expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
          described_class.new(processor_setup_intent)
        end
      end
    end
  end
end
