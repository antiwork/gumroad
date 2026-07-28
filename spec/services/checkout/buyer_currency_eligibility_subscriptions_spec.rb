# frozen_string_literal: true

require "spec_helper"

# The subscription ramp lifts four gates that previously kept every membership out of the
# buyer-currency lane. These specs pin each one, and pin what must STAY excluded.
describe Checkout::BuyerCurrencyEligibility, "subscription ramp" do
  let(:seller) { create(:user) }
  let(:membership) { create(:membership_product, user: seller, price_cents: 1000) }

  before do
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
  end

  describe ".subscriptions_enabled?" do
    it "is false until the subscription ramp flag is on, even with the lane enabled" do
      expect(described_class.subscriptions_enabled?(seller)).to be(false)
    end

    it "is true once the subscription ramp flag is on, now that both halves are wired" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)

      expect(described_class.subscriptions_enabled?(seller)).to be(true)
    end

    it "is false when the parent lane is off, so the subscription flag cannot enable it alone" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.deactivate_user(:buyer_local_currency, seller)

      expect(described_class.subscriptions_enabled?(seller)).to be(false)
    end
  end

  describe "product-shape gates" do
    subject(:unquotable) { described_class.send(:new, order: nil, seller:, merchant_account: nil, chargeable: nil, purchases: [], params: {}, setup_future_charges: false, off_session: false) }

    it "keeps memberships unquotable while the ramp is off" do
      expect(unquotable.send(:unquotable_product?, membership)).to be(true)
    end

    it "makes a plain membership quotable once the ramp is on" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)

      expect(unquotable.send(:unquotable_product?, membership)).to be(false)
    end

    it "keeps a free-trial membership excluded even in the ramp, because it charges $0 now" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      allow(membership).to receive(:free_trial_enabled?).and_return(true)

      expect(unquotable.send(:unquotable_product?, membership)).to be(true)
    end

    it "keeps a preorder excluded even in the ramp" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      allow(membership).to receive(:is_in_preorder_state?).and_return(true)

      expect(unquotable.send(:unquotable_product?, membership)).to be(true)
    end
  end

  describe "the quote-time mirror" do
    it "stays in lockstep with the charge-time gate for memberships" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)

      quote_side = Checkout::BuyerCurrencyQuote.send(:new, line_items: [], canonical_total_cents: 1000, ip: "1.2.3.4")
                                            .send(:quotable_product?, membership, buyer_currency: "eur")
      charge_side = !described_class.send(:new, order: nil, seller:, merchant_account: nil, chargeable: nil, purchases: [], params: {}, setup_future_charges: false, off_session: false)
                                    .send(:unquotable_product?, membership)

      expect(quote_side).to eq(charge_side)
    end

    it "stays in lockstep when the ramp is off too" do
      quote_side = Checkout::BuyerCurrencyQuote.send(:new, line_items: [], canonical_total_cents: 1000, ip: "1.2.3.4")
                                            .send(:quotable_product?, membership, buyer_currency: "eur")
      charge_side = !described_class.send(:new, order: nil, seller:, merchant_account: nil, chargeable: nil, purchases: [], params: {}, setup_future_charges: false, off_session: false)
                                    .send(:unquotable_product?, membership)

      expect(quote_side).to eq(charge_side)
      expect(quote_side).to be(false)
    end
  end

  describe "the off_session gate" do
    let(:subscription) { create(:subscription, link: membership, user: create(:user)) }
    let!(:original) do
      create(:membership_purchase, link: membership, seller:, subscription:,
                                   is_original_subscription_purchase: true)
    end
    let(:renewal) do
      create(:membership_purchase, link: membership, seller:, subscription:,
                                   is_original_subscription_purchase: false)
    end

    def eligibility(purchases:)
      described_class.send(:new, order: nil, seller:, merchant_account: nil, chargeable: nil,
                                 purchases:, params: {}, setup_future_charges: false, off_session: true)
    end

    it "stays closed for a renewal with no stored amount, so it charges canonical USD" do
      expect(eligibility(purchases: [renewal]).send(:subscription_renewal_with_stored_amount?)).to be(false)
    end

    it "opens for a renewal that has a stored amount" do
      create(:later_charge_presentment, owner: subscription, presentment_currency: "eur",
                                        presentment_price_cents: 899, signup_currency_units_per_usd: BigDecimal("1.111111111111111"))

      expect(eligibility(purchases: [renewal]).send(:subscription_renewal_with_stored_amount?)).to be(true)
    end

    it "does not consult the ramp flag, so pulling it never orphans an existing member" do
      create(:later_charge_presentment, owner: subscription, presentment_currency: "eur",
                                        presentment_price_cents: 899, signup_currency_units_per_usd: BigDecimal("1.111111111111111"))
      Feature.deactivate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)

      expect(eligibility(purchases: [renewal]).send(:subscription_renewal_with_stored_amount?)).to be(true)
    end
  end

  describe "the setup_future_charges gate" do
    let(:subscription) { create(:subscription, link: membership, user: create(:user)) }

    def eligibility(purchases:)
      described_class.send(:new, order: nil, seller:, merchant_account: nil, chargeable: nil,
                                 purchases:, params: {}, setup_future_charges: true, off_session: false)
    end

    it "opens for a membership signup once the ramp is on" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      signup = create(:membership_purchase, link: membership, seller:, subscription:,
                                            is_original_subscription_purchase: true)

      expect(eligibility(purchases: [signup]).send(:subscription_setup_in_ramp?)).to be(true)
    end

    it "stays closed while the ramp is off" do
      signup = create(:membership_purchase, link: membership, seller:, subscription:,
                                            is_original_subscription_purchase: true)

      expect(eligibility(purchases: [signup]).send(:subscription_setup_in_ramp?)).to be(false)
    end

    it "stays closed for a plain card-saving one-off, which is not a subscription at all" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      one_off = create(:purchase, link: create(:product, user: seller), seller:)

      expect(eligibility(purchases: [one_off]).send(:subscription_setup_in_ramp?)).to be(false)
    end

    it "stays closed for an installment payment, which is recurring but charges one instalment" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      installment = create(:membership_purchase, link: membership, seller:, subscription:,
                                                 is_original_subscription_purchase: true)
      # is_installment_payment is a flag bit rather than a column, so it cannot be written
      # with update_columns.
      allow(installment).to receive(:is_installment_payment?).and_return(true)

      expect(eligibility(purchases: [installment]).send(:subscription_setup_in_ramp?)).to be(false)
    end

    it "stays closed for a free-trial membership, whose first charge is nothing" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      signup = create(:membership_purchase, link: membership, seller:, subscription:,
                                            is_original_subscription_purchase: true)
      # Stubbed on the association the service actually reads (purchase.link), rather than
      # any_instance, so the stub cannot leak into sibling examples that expect a plain
      # membership to be eligible.
      allow(signup).to receive(:link).and_return(membership)
      allow(membership).to receive(:free_trial_enabled?).and_return(true)

      expect(eligibility(purchases: [signup]).send(:subscription_setup_in_ramp?)).to be(false)
    end

    it "stays closed for a cart mixing a membership with a one-off" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      signup = create(:membership_purchase, link: membership, seller:, subscription:,
                                            is_original_subscription_purchase: true)
      one_off = create(:purchase, link: create(:product, user: seller), seller:)

      expect(eligibility(purchases: [signup, one_off]).send(:subscription_setup_in_ramp?)).to be(false)
    end
  end
end
