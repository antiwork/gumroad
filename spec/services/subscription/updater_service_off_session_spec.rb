# frozen_string_literal: true

require "spec_helper"

describe Subscription::UpdaterService, "#charge_user! off_session behavior" do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:buyer) { create(:user) }
  let!(:subscription) do
    sub = create(:subscription, link: product, user: buyer)
    create(:purchase,
           link: product,
           purchaser: buyer,
           email: buyer.email,
           subscription: sub,
           is_original_subscription_purchase: true,
           price_cents: product.price_cents,
           variant_attributes: product.tiers.to_a)
    sub.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
    sub
  end

  let(:successful_purchase) do
    instance_double(
      Purchase,
      successful?: true,
      test_successful?: false,
      in_progress?: false,
      errors: double(full_messages: []),
      error_code: nil,
      charge_intent: nil,
      external_id: "ext_123"
    )
  end

  def build_updater(extra_params: {})
    updater = Subscription::UpdaterService.new(
      subscription: subscription,
      params: {
        price_id: product.prices.alive.first.external_id,
        variants: subscription.original_purchase.variant_attributes.map(&:external_id),
        perceived_price_cents: product.price_cents,
        perceived_upgrade_price_cents: product.price_cents,
        use_existing_card: true,
      }.merge(extra_params),
      logged_in_user: buyer,
      gumroad_guid: SecureRandom.uuid,
      remote_ip: "127.0.0.1"
    )

    updater.original_purchase = subscription.original_purchase
    updater.original_price = subscription.price
    updater.prorated_discount_price_cents = 0
    updater.overdue_for_charge = true
    updater.is_resubscribing = true
    updater
  end

  context "when stripe_setup_intent_id is present (SetupIntent already authenticated SCA)" do
    it "passes off_session: true to subscription.charge!" do
      mandate_card = instance_double(CreditCard, requires_mandate?: true)
      allow(subscription).to receive(:credit_card_to_charge).and_return(mandate_card)
      allow(subscription).to receive(:charge!).and_return(successful_purchase)

      updater = build_updater(extra_params: { stripe_setup_intent_id: "seti_123" })
      updater.send(:charge_user!)

      expect(subscription).to have_received(:charge!).with(
        hash_including(off_session: true)
      )
    end

    it "does not merge setup_future_charges into purchase params" do
      mandate_card = instance_double(CreditCard, requires_mandate?: true)
      allow(subscription).to receive(:credit_card_to_charge).and_return(mandate_card)
      allow(subscription).to receive(:charge!).and_return(successful_purchase)

      updater = build_updater(extra_params: { stripe_setup_intent_id: "seti_123" })
      updater.send(:charge_user!)

      expect(subscription).to have_received(:charge!).with(
        hash_including(override_params: hash_not_including(:setup_future_charges))
      )
    end
  end

  context "when stripe_setup_intent_id is absent and card requires mandate" do
    it "passes off_session: false to subscription.charge!" do
      mandate_card = instance_double(CreditCard, requires_mandate?: true)
      allow(subscription).to receive(:credit_card_to_charge).and_return(mandate_card)
      allow(subscription).to receive(:charge!).and_return(successful_purchase)

      updater = build_updater
      updater.send(:charge_user!)

      expect(subscription).to have_received(:charge!).with(
        hash_including(off_session: false)
      )
    end

    it "merges setup_future_charges into purchase params" do
      mandate_card = instance_double(CreditCard, requires_mandate?: true)
      allow(subscription).to receive(:credit_card_to_charge).and_return(mandate_card)
      allow(subscription).to receive(:charge!).and_return(successful_purchase)

      updater = build_updater
      updater.send(:charge_user!)

      expect(subscription).to have_received(:charge!).with(
        hash_including(override_params: hash_including(setup_future_charges: true))
      )
    end
  end

  context "when stripe_setup_intent_id is absent and card does not require mandate" do
    it "passes off_session: true to subscription.charge!" do
      non_mandate_card = instance_double(CreditCard, requires_mandate?: false)
      allow(subscription).to receive(:credit_card_to_charge).and_return(non_mandate_card)
      allow(subscription).to receive(:charge!).and_return(successful_purchase)

      updater = build_updater
      updater.send(:charge_user!)

      expect(subscription).to have_received(:charge!).with(
        hash_including(off_session: true)
      )
    end
  end
end
