# frozen_string_literal: true

require "spec_helper"

# The durable-medium confirmation Directive (EU) 2023/2673 asks for: the receipt restates what the
# buyer agreed to, with the wording version they saw. Ruling on antiwork/gumroad-private#4574.
describe ReceiptPresenter::ItemInfo, "EU withdrawal consent note" do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let!(:merchant_account) do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end
  let(:purchase) { create(:purchase, link: product, seller:, merchant_account:) }
  let(:notes) { described_class.new(purchase).props[:notes].join(" ") }

  it "prints the confirmation, with the wording version and the date, when checkout captured the consent" do
    purchase.update!(
      eu_withdrawal_consent_at: "2026-11-15T09:00:00Z",
      eu_withdrawal_consent_version: Purchase::EU_WITHDRAWAL_CONSENT_VERSION
    )

    expect(notes).to include("EU statutory right of withdrawal")
    expect(notes).to include(Purchase::EU_WITHDRAWAL_CONSENT_VERSION)
    expect(notes).to include("15 November 2026")
  end

  it "prints nothing when no consent was captured" do
    expect(notes).not_to include("withdrawal")
  end
end
