# frozen_string_literal: true

require "spec_helper"

describe Purchase, "collab purchase that also credits a direct affiliate" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:collaborator) do
    create(:collaborator, seller:, affiliate_user: create(:user), affiliate_basis_points: 5000, products: [product])
  end
  let(:direct_affiliate) do
    create(:direct_affiliate, seller:, affiliate_user: create(:user), affiliate_basis_points: 5000, products: [product])
  end
  let(:purchase) do
    purchase = Purchase.new(link: product, seller:, affiliate: collaborator, price_cents: 100, fee_cents: 60)
    purchase.direct_affiliate_id = direct_affiliate.id
    purchase.direct_affiliate_credit_cents = 0
    purchase.affiliate_credit_cents = 19
    purchase
  end
  let(:collaborator_credit) do
    AffiliateCredit.new(purchase:, affiliate: collaborator, amount_cents: 19, fee_cents: 0, basis_points: 5000,
                        is_direct_affiliate_credit: false)
  end

  before { purchase.affiliate_credit = collaborator_credit }

  it "splits a partial reversal without reading a direct credit that rounded to zero" do
    seller_cents, reversals = purchase.send(:partial_affiliate_reversals, 100, 10)

    expect(reversals.map { |_credit, amount_cents, _fee_cents| amount_cents }).to eq([25])
    expect(seller_cents).to eq(65)
  end

  it "counts a cut that floors below zero as no credit, so the sum matches what gets posted" do
    allow(purchase).to receive(:displayed_price_usd_cents).and_return(100)
    allow(seller).to receive(:bears_affiliate_fee?).and_return(true)

    expect(purchase.send(:determine_affiliate_balance_cents)).to eq(50)
    expect(purchase.direct_affiliate_credit_cents).to eq(50)
  end

  it "gives back the fee the collaborator paid at checkout when the seller bears the fee" do
    purchase.fee_cents = 1_000
    collaborator_credit.fee_cents = 500
    collaborator_credit.amount_cents = 3_500
    collaborator_credit.basis_points = 5000
    allow(purchase).to receive(:credits_direct_affiliate?).and_return(true)
    allow(purchase).to receive(:direct_affiliate_price_share).and_return(0.2)

    amount_cents, fee_cents = purchase.send(:affiliate_reversal_amounts, collaborator_credit, 5_000, 500)

    expect(fee_cents).to eq(250)
    expect(amount_cents).to eq(1_750)
  end
end
