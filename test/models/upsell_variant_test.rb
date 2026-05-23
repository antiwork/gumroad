# frozen_string_literal: true

require "test_helper"

class UpsellVariantTest < ActiveSupport::TestCase
  self.described_class = UpsellVariant



  context_ UpsellVariant do
  context_ "validations" do
  context_ "when the variants don't belong to the upsell's offered product" do
        before do
          @upsell_variant = build(:upsell_variant, selected_variant: create(:variant), offered_variant: create(:variant))
        end

  test "adds an error" do
          expect(@upsell_variant.valid?).to eq(false)
          expect(@upsell_variant.errors.full_messages.first).to eq("The selected variant and the offered variant must belong to the upsell's offered product.")
        end
      end
    end

  context_ "when the variants belong to the upsell's offered product" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @upsell = create(:upsell, product: @product, seller: @seller)
        @upsell_variant = build(:upsell_variant, upsell: @upsell, selected_variant: create(:variant, variant_category: create(:variant_category, link: @product)), offered_variant: create(:variant, variant_category: create(:variant_category, link: @product)))
      end

  test "doesn't add an error" do
        expect(@upsell_variant.valid?).to eq(true)
      end
    end
  end
end
