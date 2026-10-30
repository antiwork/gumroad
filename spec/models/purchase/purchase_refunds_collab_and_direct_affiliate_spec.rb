# frozen_string_literal: true

require "spec_helper"

describe "refunds and chargebacks of a collab purchase that also credits a direct affiliate",
         vcr: { cassette_name: "PurchaseCollabAndDirectAffiliate/checkout" } do
  let!(:gumroad_merchant_account) { create(:merchant_account, user: nil, currency: Currency::USD) }
  let(:seller) { create(:user, bears_affiliate_fee: true) }
  let(:product) { create(:product, user: seller, price_cents: 225_00) }
  let(:collaborator_user) { create(:user) }
  let(:direct_affiliate_user) { create(:user) }
  let(:collaborator) do
    create(:collaborator, seller:, affiliate_user: collaborator_user, affiliate_basis_points: 5000)
  end
  let(:direct_affiliate) do
    create(:direct_affiliate, seller:, affiliate_user: direct_affiliate_user, affiliate_basis_points: 1000, products: [product])
  end
  let(:collab_and_affiliates_enabled) { true }
  let(:purchase) do
    params = {
      purchase: {
        email: "buyer@example.com",
        quantity: 1,
        perceived_price_cents: product.price_cents,
        affiliate_id: direct_affiliate.id,
        chargeable: create(:chargeable),
      }
    }
    purchase, error = Purchase::CreateService.new(product:, params:).perform
    expect(error).to be_nil
    expect(purchase).to be_successful
    purchase
  end
  let(:collaborator_credit) { purchase.affiliate_credit.reload }
  let(:direct_credit) { purchase.direct_affiliate_credit.reload }

  before do
    Feature.activate_user(:collab_and_affiliates, seller)
    create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 5000)
    direct_affiliate
    Feature.deactivate_user(:collab_and_affiliates, seller) unless collab_and_affiliates_enabled
    purchase
  end

  def verify_balance(user, expected_balance)
    expect(user.reload.unpaid_balance_cents).to eq expected_balance
  end

  it "credits the direct affiliate before splitting the remaining price" do
    expect(direct_credit).to have_attributes(amount_cents: 22_50, fee_cents: 0, basis_points: 1000)
    expect(collaborator_credit).to have_attributes(amount_cents: 8_633, fee_cents: 1_492, basis_points: 5000)
    expect(purchase.affiliate_credit_cents).to eq(10_883)
    verify_balance(collaborator_user, 8_633)
    verify_balance(direct_affiliate_user, 22_50)
    verify_balance(seller, 8_634)
  end

  # Refund recordings keep their own charge IDs and refund histories.
  it "reverses both credits on a full refund", vcr: { cassette_name: "PurchaseCollabAndDirectAffiliate/full_refund" } do
    purchase.refund_and_save!(create(:admin_user).id, reason: "Refund requested by the buyer")

    expect(collaborator_credit.affiliate_credit_refund_balance).to be_present
    expect(direct_credit.affiliate_credit_refund_balance).to be_present
    verify_balance(collaborator_user, 0)
    verify_balance(direct_affiliate_user, 0)
    verify_balance(seller, -1 * (22_500 * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round)
  end

  it "reverses each credit by its own share of a partial refund", vcr: { cassette_name: "PurchaseCollabAndDirectAffiliate/partial_refund" } do
    purchase.refund_and_save!(create(:admin_user).id, amount_cents: 11_250, reason: "Refund requested by the buyer")

    expect(purchase.refunds.last).to have_attributes(amount_cents: 11_250, fee_cents: 1_491, retained_fee_cents: 342)
    expect(purchase.affiliate_partial_refunds.count).to eq(2)
    expect(purchase.affiliate_partial_refunds.find_by(affiliate_user: collaborator_user))
      .to have_attributes(total_credit_cents: 8_633, amount_cents: 4_318, fee_cents: 745)
    expect(purchase.affiliate_partial_refunds.find_by(affiliate_user: direct_affiliate_user))
      .to have_attributes(total_credit_cents: 22_50, amount_cents: 1_125, fee_cents: 0)

    verify_balance(collaborator_user, 4_315)
    verify_balance(direct_affiliate_user, 1_125)
    verify_balance(seller, 4_721)
  end

  it "debits both credits on a chargeback" do
    dispute = create(:dispute_formalized, purchase:)
    flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -1 * purchase.total_transaction_cents)

    purchase.decrement_balance_for_refund_or_chargeback!(flow_of_funds, dispute:)

    expect(collaborator_credit.affiliate_credit_chargeback_balance).to be_present
    expect(direct_credit.affiliate_credit_chargeback_balance).to be_present
    verify_balance(collaborator_user, 0)
    verify_balance(direct_affiliate_user, 0)
    verify_balance(seller, 0)
  end

  it "re-credits both credits when the dispute is won" do
    dispute = create(:dispute_formalized, purchase:)
    chargedback = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -1 * purchase.total_transaction_cents)
    purchase.decrement_balance_for_refund_or_chargeback!(chargedback, dispute:)
    won = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents)

    expect { purchase.create_credit_for_dispute_won!(won) }.to change { Credit.count }.by(3)

    expect(Credit.where(user: collaborator_user).last.balance_transaction.balance.amount_cents).to eq(8_633)
    expect(Credit.where(user: direct_affiliate_user).last.balance_transaction.balance.amount_cents).to eq(22_50)
    verify_balance(collaborator_user, 8_633)
    verify_balance(direct_affiliate_user, 22_50)
    verify_balance(seller, 8_634)
  end

  context "when the seller's flag is disabled" do
    let(:collab_and_affiliates_enabled) { false }

    it "keeps the collaborator as the only affiliate" do
      expect(purchase.affiliate).to eq(collaborator)
      expect(purchase.direct_affiliate_id).to be_nil
      expect(purchase.direct_affiliate_credit).to be_nil
      expect(purchase.affiliate_credit_cents).to eq(9_758)
    end
  end
end
