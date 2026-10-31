# frozen_string_literal: true

require "spec_helper"

describe Purchase, "collab purchase that also credits a direct affiliate" do
  let!(:gumroad_merchant_account) { create(:merchant_account, user: nil, currency: Currency::USD) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:collaborator) do
    create(:collaborator, seller:, affiliate_user: create(:user), affiliate_basis_points: 5000)
  end
  let(:direct_affiliate) do
    create(:direct_affiliate, seller:, affiliate_user: create(:user), affiliate_basis_points: 5000, products: [product])
  end
  let(:purchase) do
    build(:purchase, link: product, seller:, affiliate: collaborator, price_cents: 100).tap do |purchase|
      purchase.fee_cents = 60
      purchase.direct_affiliate_id = direct_affiliate.id
      purchase.direct_affiliate_credit_cents = 0
      purchase.affiliate_credit_cents = 19
    end
  end
  let(:collaborator_credit) do
    build(:affiliate_credit, purchase:, affiliate: collaborator, affiliate_user: collaborator.affiliate_user,
                             amount_cents: 19, fee_cents: 0, basis_points: 5000, is_direct_affiliate_credit: false)
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

  it "keeps the purchase-time rate when the direct credit rounds to zero" do
    direct_affiliate.update!(affiliate_basis_points: 100)
    paid_purchase = create(:purchase, link: product, affiliate: collaborator, price_cents: 100,
                                      direct_affiliate_id: direct_affiliate.id)
    paid_purchase.increment_affiliates_balance!
    expect(paid_purchase.direct_affiliate_credit).to be_nil
    expect(paid_purchase.affiliate_credit).to have_attributes(amount_cents: 3, fee_cents: 47)

    direct_affiliate.update!(affiliate_basis_points: 5000)
    paid_purchase = Purchase.find(paid_purchase.id)

    expect(paid_purchase.affiliate_reversal_amounts(paid_purchase.affiliate_credit, 50, 46)).to eq([2, 23])
  end

  it "posts the recorded rate when the affiliate changes before the credit is posted" do
    direct_affiliate.update!(affiliate_basis_points: 1000)
    paid_purchase = create(:purchase, link: product, affiliate: collaborator, price_cents: 225_00,
                                      direct_affiliate_id: direct_affiliate.id)
    direct_affiliate.update!(affiliate_basis_points: 5000)

    paid_purchase = Purchase.find(paid_purchase.id)
    paid_purchase.increment_affiliates_balance!

    expect(paid_purchase.direct_affiliate_credit.basis_points).to eq(1000)
  end

  it "posts the recorded collaborator rate when its product rate changes before posting" do
    Feature.activate_user(:collab_and_affiliates, seller)
    assignment = create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 5000)
    direct_affiliate.update!(affiliate_basis_points: 1000)
    paid_purchase = create(:purchase, link: product, affiliate: collaborator, price_cents: 225_00,
                                      direct_affiliate_id: direct_affiliate.id)
    assignment.update!(affiliate_basis_points: 2500)

    paid_purchase = Purchase.find(paid_purchase.id)
    paid_purchase.increment_affiliates_balance!

    expect(paid_purchase.affiliate_credit).to have_attributes(basis_points: 5000, fee_cents: 1343)
    expect(paid_purchase.affiliate_reversal_amounts(paid_purchase.affiliate_credit, 11_250, 1491)).to eq([4392, 671])
  end
end
