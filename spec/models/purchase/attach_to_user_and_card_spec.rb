# frozen_string_literal: true

require "spec_helper"

describe Purchase, "#attach_to_user_and_card" do
  let(:user) { create(:user) }
  let(:purchase) { create(:purchase) }

  it "attaches the purchaser" do
    purchase.attach_to_user_and_card(user, nil, nil)

    expect(purchase.reload.purchaser).to eq(user)
  end

  it "attaches a successful purchase with incomplete charge fields without re-running charge validation" do
    # Older/migrated or imported purchases can be successful and paid while missing
    # charge fields, which fails financial_transaction_validation on a plain save!.
    purchase.update_columns(
      price_cents: 100,
      stripe_transaction_id: nil,
      stripe_fingerprint: nil,
      merchant_account_id: nil,
      charge_processor_id: nil
    )

    purchase.attach_to_user_and_card(user, nil, nil)

    expect(purchase.reload.purchaser).to eq(user)
  end

  it "does not attach a reassignment-locked purchase" do
    purchase.update!(is_reassignment_locked: true)

    expect(purchase.attach_to_user_and_card(user, nil, nil)).to eq(false)
    expect(purchase.reload.purchaser).to be_nil
  end
end
