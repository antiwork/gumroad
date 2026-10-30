# frozen_string_literal: true

require "spec_helper"

# A collab product that also credits the direct affiliate who referred the sale posts two credit
# rows on one purchase. Every reversal path has to reverse BOTH of them, each by its own rate, and
# leave the seller carrying the rest: a refund (Purchase#decrement_balance_for_collab_and_direct_affiliate!),
# a chargeback, and a won dispute (Purchase::DisputeWinCredits).
describe "refunds and chargebacks of a collab purchase that also credits a direct affiliate", :vcr do
  # The userless Gumroad-held platform account. The purchase factory resolves the merchant account
  # through `MerchantAccount.gumroad`, and this checkout's test database carries no such row, so
  # every money spec has to post one first.
  let!(:gumroad_merchant_account) do
    create(:merchant_account, user: nil, currency: Currency::USD,
                              charge_processor_merchant_id: "acct_collab_direct_#{SecureRandom.hex(6)}")
  end
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 225_00) }
  let(:collaborator_user) { create(:user) }
  let(:direct_affiliate_user) { create(:user) }
  let(:collaborator) do
    create(:collaborator, seller:, affiliate_user: collaborator_user, affiliate_basis_points: 5000, products: [product])
  end
  let(:direct_affiliate) do
    create(:direct_affiliate, seller:, affiliate_user: direct_affiliate_user, affiliate_basis_points: 1000, products: [product])
  end
  let(:purchase) do
    create(:purchase_in_progress, link: product, seller:, affiliate: collaborator,
                                  direct_affiliate_id: direct_affiliate.id,
                                  chargeable: create(:chargeable))
  end
  let(:collaborator_credit) { purchase.affiliate_credit.reload }
  let(:direct_credit) { purchase.direct_affiliate_credit.reload }

  # The seller bears the affiliate fee, so the direct affiliate's credit is its bare 10% and the
  # collaborator's is 50% of what is left, less its own half of the Gumroad fee.
  before do
    Feature.activate(:collab_and_affiliates)
    seller.update!(bears_affiliate_fee: true)
    collaborator
    direct_affiliate
    purchase.process!
    purchase.update_balance_and_mark_successful!
  end

  # Flipper is redis-backed here, so a global activation outlives the example and would turn the
  # flag on for every spec that runs after this file in the same process.
  after { Feature.deactivate(:collab_and_affiliates) }

  def verify_balance(user, expected_balance)
    expect(user.reload.unpaid_balance_cents).to eq expected_balance
  end

  it "credits the direct affiliate off the top and the collaborator half of what is left" do
    # On the $225 sale: 10% to the direct affiliate (22_50), then 50% of the 202_50 left (101_25)
    # less the collaborator's half of the 29_83 Gumroad fee, which checkout charges a collaborator.
    expect(direct_credit).to have_attributes(amount_cents: 22_50, fee_cents: 0, basis_points: 1000)
    expect(collaborator_credit).to have_attributes(amount_cents: 10_125 - 1_492, fee_cents: 1_492, basis_points: 5000)
    expect(purchase.affiliate_credit_cents).to eq(10_883)
    verify_balance(collaborator_user, 8_633)
    verify_balance(direct_affiliate_user, 22_50)
    verify_balance(seller, 8_634)
  end

  it "reverses both credits on a full refund and returns every balance to zero" do
    purchase.refund_and_save!(create(:admin_user).id, reason: "Refund requested by the buyer")

    expect(collaborator_credit.affiliate_credit_refund_balance).to be_present
    expect(direct_credit.affiliate_credit_refund_balance).to be_present
    verify_balance(collaborator_user, 0)
    verify_balance(direct_affiliate_user, 0)
    # The seller gives back what is left of the payment after both credits and, as on a purchase
    # with a lone affiliate, still carries the processor's fee: the sale is back to zero for it.
    verify_balance(seller, -1 * (22_500 * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round)
  end

  it "reverses each credit by its own share of a partial refund" do
    purchase.refund_and_save!(create(:admin_user).id, amount_cents: 11_250, reason: "Refund requested by the buyer")

    expect(purchase.refunds.last).to have_attributes(amount_cents: 11_250, fee_cents: 1_491, retained_fee_cents: 342)
    expect(purchase.affiliate_partial_refunds.count).to eq(2)

    # The collaborator gives back 45% of the refunded half — its 50% of the 90% left after the
    # direct affiliate's 10% — less its share of the returned fee (1_492 * 1_491 / 2_983): 4_318.
    expect(purchase.affiliate_partial_refunds.find_by(affiliate_user: collaborator_user))
      .to have_attributes(total_credit_cents: 8_633, amount_cents: 4_318, fee_cents: 745)
    # The direct affiliate gives back its own 10%, and paid no fee to give back.
    expect(purchase.affiliate_partial_refunds.find_by(affiliate_user: direct_affiliate_user))
      .to have_attributes(total_credit_cents: 22_50, amount_cents: 1_125, fee_cents: 0)

    verify_balance(collaborator_user, 8_633 - 4_318)
    verify_balance(direct_affiliate_user, 22_50 - 1_125)
    # What the seller keeps of the sale: the refunded 11_250 less the 1_491 fee, the 5_063 given
    # back to the collaborator, the 1_125 given back to the direct affiliate, and the 342 of the
    # fee Gumroad retained.
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
  end
end
