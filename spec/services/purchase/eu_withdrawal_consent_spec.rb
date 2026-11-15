# frozen_string_literal: true

require "spec_helper"

# The EU immediate-delivery / loss-of-withdrawal-right consent captured at checkout
# (Consumer Rights Directive art. 16(a)/(m), Directive (EU) 2023/2673). Ruling on
# antiwork/gumroad-private#4574.
describe Purchase::CreateService, "EU withdrawal consent" do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user, email: "eu-buyer@example.com") }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:physical_product) { create(:product, :is_physical, user: seller, price_cents: 10_00) }

  # `is_part_of_combined_charge` keeps the purchase unattached to a real card charge, which is the
  # shape the checkout's multi-line order uses.
  def create_purchase(product:, country:, eu_withdrawal_consent: nil, purchase_attributes: {})
    attributes = {
      email: buyer.email,
      quantity: 1,
      perceived_price_cents: product.price_cents,
      ip_address: "0.0.0.0",
      country:,
    }.merge(purchase_attributes)
    attributes[:eu_withdrawal_consent] = eu_withdrawal_consent unless eu_withdrawal_consent.nil?

    described_class.new(
      product:,
      params: { purchase: attributes, is_part_of_combined_charge: true },
      buyer:,
    ).perform
  end

  context "when the buyer is in an EU member state and the product is not physical" do
    it "records the consent, with the timestamp and the wording version, when the buyer agreed" do
      purchase, error = create_purchase(product:, country: "DE", eu_withdrawal_consent: true)

      expect(error).to be_nil
      expect(purchase.reload.eu_withdrawal_consent_at).to be_present
      expect(purchase.eu_withdrawal_consent_version).to eq(Purchase::EU_WITHDRAWAL_CONSENT_VERSION)
    end

    it "records nothing when the buyer did not agree" do
      purchase, error = create_purchase(product:, country: "DE", eu_withdrawal_consent: false)

      expect(error).to be_nil
      expect(purchase.reload.eu_withdrawal_consent_at).to be_nil
      expect(purchase.eu_withdrawal_consent_version).to be_nil
    end

    it "refuses the purchase when the consent is missing and the flag is on" do
      Feature.activate(:eu_withdrawal_consent)

      purchase, error = create_purchase(product:, country: "DE", eu_withdrawal_consent: false)

      expect(purchase).to be_nil
      expect(error).to include("EU right of withdrawal")
    ensure
      Feature.deactivate(:eu_withdrawal_consent)
    end

    it "still records the consent when the flag is on" do
      Feature.activate(:eu_withdrawal_consent)

      purchase, error = create_purchase(product:, country: "DE", eu_withdrawal_consent: true)

      expect(error).to be_nil
      expect(purchase.reload.eu_withdrawal_consent_at).to be_present
    ensure
      Feature.deactivate(:eu_withdrawal_consent)
    end
  end

  it "ignores the consent for a physical product, whose withdrawal right cannot be waived" do
    purchase, error = create_purchase(
      product: physical_product,
      country: "DE",
      eu_withdrawal_consent: true,
      purchase_attributes: {
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        city: "Berlin",
        state: "Berlin",
        zip_code: "10115",
      },
    )

    expect(error).to be_nil
    expect(purchase.reload.eu_withdrawal_consent_at).to be_nil
  end

  it "ignores the consent for a buyer outside the EU" do
    purchase, error = create_purchase(product:, country: "CH", eu_withdrawal_consent: true)

    expect(error).to be_nil
    expect(purchase.reload.eu_withdrawal_consent_at).to be_nil
  end

  it "treats the UK as outside the withdrawal set" do
    purchase, error = create_purchase(product:, country: "GB", eu_withdrawal_consent: true)

    expect(error).to be_nil
    expect(purchase.reload.eu_withdrawal_consent_at).to be_nil
  end
end
