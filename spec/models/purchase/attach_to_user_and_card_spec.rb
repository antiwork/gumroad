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

  describe "bundle member purchases" do
    let(:seller) { create(:user) }
    let(:bundle) { create(:product, :bundle, user: seller) }
    let(:purchase) { create(:purchase, link: bundle, seller:, is_bundle_purchase: true, email: "buyer@example.com") }
    let(:member_product) { create(:product, user: seller) }
    let!(:member) do
      create(:purchase, link: member_product, seller:, email: purchase.email, purchaser: nil).tap do |product_purchase|
        create(:bundle_product_purchase, bundle_purchase: purchase, product_purchase:)
      end
    end

    it "attaches the bundle's unclaimed members and leaves a same-email purchase that is not a member" do
      unrelated = create(:purchase, email: purchase.email, purchaser: nil, seller:, link: create(:product, user: seller))

      purchase.attach_to_user_and_card(user, nil, nil)

      expect(purchase.reload.purchaser).to eq(user)
      expect(member.reload.purchaser).to eq(user)
      expect(unrelated.reload.purchaser).to be_nil
    end

    it "attaches a member whose charge fields would fail validation" do
      member.update_columns(
        price_cents: 100,
        stripe_transaction_id: nil,
        stripe_fingerprint: nil,
        merchant_account_id: nil,
        charge_processor_id: nil
      )

      purchase.attach_to_user_and_card(user, nil, nil)

      expect(member.reload.purchaser).to eq(user)
    end

    it "does not move a member that already has a purchaser, a different email, or a reassignment lock" do
      other = create(:user)
      claimed = create(:purchase, link: member_product, seller:, email: purchase.email, purchaser: other)
      create(:bundle_product_purchase, bundle_purchase: purchase, product_purchase: claimed)
      mismatched = create(:purchase, link: member_product, seller:, email: "other@example.com", purchaser: nil)
      create(:bundle_product_purchase, bundle_purchase: purchase, product_purchase: mismatched)
      locked = create(:purchase, link: member_product, seller:, email: purchase.email, purchaser: nil, is_reassignment_locked: true)
      create(:bundle_product_purchase, bundle_purchase: purchase, product_purchase: locked)

      purchase.update!(purchaser: user)

      expect(member.reload.purchaser).to eq(user)
      expect(claimed.reload.purchaser).to eq(other)
      expect(mismatched.reload.purchaser).to be_nil
      expect(locked.reload.purchaser).to be_nil
    end

    it "does not clear member purchasers when the parent purchaser is removed" do
      purchase.update!(purchaser: user)
      purchase.update!(purchaser: nil)

      expect(member.reload.purchaser).to eq(user)
    end
  end
end
