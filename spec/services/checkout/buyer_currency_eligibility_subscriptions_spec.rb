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
    it "keeps memberships unquotable while the ramp is off" do
      expect(described_class.unquotable_product?(membership)).to be(true)
    end

    it "makes a plain membership quotable once the ramp is on" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)

      expect(described_class.unquotable_product?(membership)).to be(false)
    end

    it "keeps a free-trial membership excluded even in the ramp, because it charges $0 now" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      allow(membership).to receive(:free_trial_enabled?).and_return(true)

      expect(described_class.unquotable_product?(membership)).to be(true)
    end

    it "makes a preorder quotable once the later-charge ramp is on" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      allow(membership).to receive(:is_in_preorder_state?).and_return(true)

      expect(described_class.unquotable_product?(membership)).to be(false)
    end
  end

  # Three separate places decide whether a membership may be priced in the buyer's currency:
  # the product page's display gate, the surcharge endpoint that mints the quote, and the
  # charge path that honours the resulting token. They must all give the same answer. When only
  # two of them were lifted, the product page showed US dollars while the same checkout quoted
  # the buyer's currency, so the price changed between the page and the till.
  describe "the three product-shape gates" do
    # The display gate lives in a helper, so exercise it through an object that includes the
    # helper rather than reaching into the view layer.
    let(:display_gate) { Class.new { include CurrencyHelper }.new }

    def gate_answers
      quotable_at_quote_time = Checkout::BuyerCurrencyQuote.send(:new, line_items: [], canonical_total_cents: 1000, ip: "1.2.3.4")
                                                          .send(:quotable_product?, membership, buyer_currency: "eur")
      quotable_at_charge_time = !described_class.unquotable_product?(membership)
      quotable_on_product_page = !display_gate.buyer_currency_unquotable_product?(membership)

      [quotable_on_product_page, quotable_at_quote_time, quotable_at_charge_time]
    end

    it "all say a membership is quotable once the ramp is on" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)

      expect(gate_answers).to eq([true, true, true])
    end

    it "all say a membership is not quotable while the ramp is off" do
      expect(gate_answers).to eq([false, false, false])
    end

    it "all keep a free-trial membership out, ramp or no ramp, because its first charge is $0" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      membership.update!(free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)

      expect(gate_answers).to eq([false, false, false])
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

    it "opens for an installment payment whose later amounts can be fixed" do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      installment = create(:membership_purchase, link: membership, seller:, subscription:,
                                                 is_original_subscription_purchase: true)
      # is_installment_payment is a flag bit rather than a column, so it cannot be written
      # with update_columns.
      allow(installment).to receive(:is_installment_payment?).and_return(true)

      expect(eligibility(purchases: [installment]).send(:subscription_setup_in_ramp?)).to be(true)
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
