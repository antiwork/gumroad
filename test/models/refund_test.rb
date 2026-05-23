# frozen_string_literal: true

require "test_helper"

class RefundTest < ActiveSupport::TestCase
  self.described_class = Refund



  context_ Refund do
  test "validates that processor_refund_id is unique"  do
      create(:refund, processor_refund_id: "ref_id")
      new_ref = build(:refund, processor_refund_id: "ref_id")
      expect(new_ref.valid?).not_to be(true)
    end

  context_ "flags" do
  test "has an `is_for_fraud` flag" do
        flag_on = create(:refund, is_for_fraud: true)
        flag_off = create(:refund, is_for_fraud: false)

        expect(flag_on.is_for_fraud).to be true
        expect(flag_off.is_for_fraud).to be false
      end
    end

  test "sets the product and the seller of the purchase" do
      refund = create(:refund)
      expect(refund.product).to eq(refund.purchase.link)
      expect(refund.seller).to eq(refund.purchase.seller)
    end
  end
end
