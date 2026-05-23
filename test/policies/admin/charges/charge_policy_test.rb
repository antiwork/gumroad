# frozen_string_literal: true

require "test_helper"

class AdminChargesChargePolicyTest < ActiveSupport::TestCase
  self.described_class = Admin::Charges::ChargePolicy
  self.rspec_metadata = { vcr: true }



  context_ Admin::Charges::ChargePolicy, :vcr do
    subject { described_class }

    let(:admin_user) { create(:admin_user) }
    let(:seller_context) { SellerContext.new(user: admin_user, seller: admin_user) }

    permissions :refund? do
      let(:charge) do
        purchase = create(:purchase_in_progress, chargeable: create(:chargeable))
        purchase.process!
        purchase.update_balance_and_mark_successful!
        purchase_2 = create(:purchase_in_progress, chargeable: create(:chargeable))
        purchase_2.process!
        purchase_2.update_balance_and_mark_successful!
        charge = create(:charge, purchases: [purchase, purchase_2])
        charge
      end

  context_ "when charge has non-refunded purchases" do
  test "grants access" do
          expect(subject).to permit(seller_context, charge)
        end
      end

  context_ "when all purchases are already refunded" do
        before do
          charge.purchases.each { _1.update!(stripe_refunded: 1) }
        end

  test "denies access" do
          expect(subject).not_to permit(seller_context, charge)
        end
      end
    end

    permissions :sync_status_with_charge_processor? do
      let(:charge) do
        purchase = create(:purchase_in_progress, chargeable: create(:chargeable))
        purchase_2 = create(:purchase_in_progress, chargeable: create(:chargeable))
        charge = create(:charge, purchases: [purchase, purchase_2])
        charge
      end

  context_ "when charge has in_progress purchases" do
  test "grants access" do
          expect(subject).to permit(seller_context, charge)
        end
      end

  context_ "when charge has failed purchases" do
        before do
          charge.purchases.each { _1.mark_failed! }
        end

  test "grants access" do
          expect(subject).to permit(seller_context, charge)
        end
      end

  context_ "when no purchases are in progress or failed" do
        before do
          charge.purchases.each do |purchase|
            purchase.process!
            purchase.update_balance_and_mark_successful!
          end
        end

  test "denies access" do
          expect(subject).not_to permit(seller_context, charge)
        end
      end
    end
  end
end
