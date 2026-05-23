# frozen_string_literal: true

require "test_helper"

class SellerRefundPolicyTest < ActiveSupport::TestCase
  self.described_class = SellerRefundPolicy



  context_ SellerRefundPolicy do
    let(:seller) { create(:named_seller) }
    let(:refund_policy) { seller.refund_policy }

  context_ "validations" do
  test "validates presence" do
        refund_policy = SellerRefundPolicy.new

        expect(refund_policy.valid?).to be false
        expect(refund_policy.errors.details[:seller].first[:error]).to eq :blank
      end

  context_ "when refund policy for seller exists" do
  test "validates seller uniqueness" do
          new_refund_policy = refund_policy.dup

          expect(new_refund_policy.valid?).to be false
          expect(new_refund_policy.errors.details[:seller].first[:error]).to eq :taken
        end
      end

  test "validates fine_print length" do
        refund_policy.fine_print = "a" * 3001
        expect(refund_policy.valid?).to be false
        expect(refund_policy.errors.details[:fine_print].first[:error]).to eq :too_long
      end

  test "strips tags" do
        refund_policy.fine_print = "<p>This is a account-level refund policy</p>"
        refund_policy.save!

        expect(refund_policy.fine_print).to eq "This is a account-level refund policy"
      end
    end

  context_ "stripped_fields" do
      before do
        refund_policy.update!(fine_print: "  This is a account-level refund policy  ")
      end

  test "strips leading and trailing spaces for fine_print" do
        expect(refund_policy.fine_print).to eq "This is a account-level refund policy"
      end

  test "nullifies fine_print" do
        refund_policy.update!(fine_print: "")

        expect(refund_policy.fine_print).to be_nil
      end
    end

  context_ "#as_json" do
  test "returns a hash with refund details" do
        expect(refund_policy.as_json).to eq(
          {
            fine_print: refund_policy.fine_print,
            id: refund_policy.external_id,
            title: refund_policy.title,
          }
        )
      end
    end
  end
end
