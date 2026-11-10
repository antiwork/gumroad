# frozen_string_literal: true

require "spec_helper"

describe Purchase, "sharing the provider's processing fee with collaborators" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 6900) }
  let(:collaborator) { create(:collaborator, seller:, affiliate_user: create(:user), affiliate_basis_points: 5000) }
  let(:purchase) { build(:purchase, link: product, seller:, affiliate: collaborator, price_cents: 6900).tap { |p| p.fee_cents = 740 } }

  it "uses only Gumroad's fee when there is no separate provider fee" do
    expect(purchase.send(:determine_affiliate_fee_cents)).to eq(370)
    expect(purchase.send(:determine_affiliate_balance_cents)).to eq(3080)
  end

  it "adds the USD-converted provider fee when it is booked separately" do
    allow(purchase).to receive(:paypal_fee_usd_cents).and_return(348)

    expect(purchase.send(:determine_affiliate_fee_cents)).to eq(544)
    expect(purchase.send(:determine_affiliate_balance_cents)).to eq(2906)
  end

  it "recomputes the credit at success so a fee known only after capture is shared" do
    paid = purchase
    allow(paid).to receive(:paypal_fee_usd_cents).and_return(348)
    allow(paid).to receive(:increment_sellers_balance!)
    allow(paid).to receive(:mark_successful!)
    paid.update_balance_and_mark_successful!

    expect(paid.affiliate_credit_cents).to eq(2906)
  end
end
