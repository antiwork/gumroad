# frozen_string_literal: true

require "test_helper"

class ProductRefundPolicyTest < ActiveSupport::TestCase
  self.described_class = ProductRefundPolicy



  context_ ProductRefundPolicy do
    let(:refund_policy) { create(:product_refund_policy) }

  context_ "validations" do
  test "validates presence" do
        refund_policy = ProductRefundPolicy.new

        expect(refund_policy.valid?).to be false
        expect(refund_policy.errors.details[:seller].first[:error]).to eq :blank
        expect(refund_policy.errors.details[:product].first[:error]).to eq :blank
      end

  context_ "when refund policy for product exists" do
  test "validates product uniqueness" do
          new_refund_policy = refund_policy.dup

          expect(new_refund_policy.valid?).to be false
          expect(new_refund_policy.errors.details[:product].first[:error]).to eq :taken
        end
      end

  test "validates fine_print length" do
        refund_policy.fine_print = "a" * 3001
        expect(refund_policy.valid?).to be false
        expect(refund_policy.errors.details[:fine_print].first[:error]).to eq :too_long
      end

  test "strips tags" do
        refund_policy.fine_print = "<p>This is a product-level refund policy</p>"
        refund_policy.save!

        expect(refund_policy.fine_print).to eq "This is a product-level refund policy"
      end

  test "is invalid when the product belongs to the seller" do
        refund_policy = create(:product_refund_policy)
        refund_policy.product = create(:product)

        expect(refund_policy.valid?).to be false
        expect(refund_policy.errors.details[:product].first[:error]).to eq :invalid
      end

  context_ "max_refund_period_in_days validation" do
  test "is valid with allowed refund period values" do
          RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.keys.each do |days|
            refund_policy.max_refund_period_in_days = days
            expect(refund_policy.valid?).to be true
          end
        end

  test "is invalid with nil value" do
          refund_policy.max_refund_period_in_days = nil
          expect(refund_policy.valid?).to be false
          expect(refund_policy.errors.details[:max_refund_period_in_days].first[:error]).to eq :inclusion
        end

  test "is invalid with a refund period not in the allowed list" do
          [1, 15, 60, 200].each do |days|
            refund_policy.max_refund_period_in_days = days
            expect(refund_policy.valid?).to be false
            expect(refund_policy.errors.details[:max_refund_period_in_days].first[:error]).to eq :inclusion
          end
        end
      end
    end

  context_ "stripped_fields" do
  test "strips leading and trailing spaces for fine_print" do
        refund_policy = create(:product_refund_policy, fine_print: "  This is a product-level refund policy  ")

        expect(refund_policy.fine_print).to eq "This is a product-level refund policy"
      end

  test "nullifies fine_print" do
        refund_policy = create(:product_refund_policy, fine_print: "")

        expect(refund_policy.fine_print).to be_nil
      end
    end

  context_ "#as_json" do
      let(:refund_policy) { create(:product_refund_policy) }

  test "returns a hash with refund details" do
        expect(refund_policy.as_json).to eq(
          {
            fine_print: refund_policy.fine_print,
            id: refund_policy.external_id,
            max_refund_period_in_days: refund_policy.max_refund_period_in_days,
            product_name: refund_policy.product.name,
            title: refund_policy.title,
          }
        )
      end
    end

  context_ "scopes" do
  context_ "for_visible_and_not_archived_products" do
        let!(:refund_policy_archived_product) { create(:product_refund_policy, product: create(:product, archived: true)) }
        let!(:refund_policy_deleted_product) { create(:product_refund_policy, product: create(:product, deleted_at: Time.current)) }
        let!(:refund_policy_product) { create(:product_refund_policy, product: create(:product)) }

  test "returns the correct record" do
          expect(ProductRefundPolicy.for_visible_and_not_archived_products).to eq [refund_policy_product]
        end
      end
    end

  context_ "#no_refunds?" do
      let(:refund_policy) { create(:product_refund_policy) }

  test "returns true when max_refund_period_in_days is 0" do
        refund_policy.max_refund_period_in_days = 0
        expect(refund_policy.no_refunds?).to be true
      end

  test "returns false when max_refund_period_in_days is not 0" do
        [7, 14, 30, 183].each do |days|
          refund_policy.max_refund_period_in_days = days
          expect(refund_policy.no_refunds?).to be false
        end
      end
    end

  context_ "#published_and_no_refunds?" do
      let(:refund_policy) { create(:product_refund_policy) }

  test "returns true when product is published and has no refunds" do
        allow(refund_policy.product).to receive(:published?).and_return(true)
        allow(refund_policy).to receive(:no_refunds?).and_return(true)
        expect(refund_policy.published_and_no_refunds?).to be true
      end

  test "returns false when product is not published" do
        allow(refund_policy.product).to receive(:published?).and_return(false)
        allow(refund_policy).to receive(:no_refunds?).and_return(true)
        expect(refund_policy.published_and_no_refunds?).to be false
      end

  test "returns false when refunds are allowed" do
        allow(refund_policy.product).to receive(:published?).and_return(true)
        allow(refund_policy).to receive(:no_refunds?).and_return(false)
        expect(refund_policy.published_and_no_refunds?).to be false
      end
    end
  end
end
