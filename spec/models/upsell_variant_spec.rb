# frozen_string_literal: true

require "spec_helper"

describe UpsellVariant do
  describe "validations" do
    context "when the variants don't belong to the upsell's offered product" do
      before do
        @upsell_variant = build(:upsell_variant, selected_variant: create(:variant), offered_variant: create(:variant))
      end

      it "adds an error" do
        expect(@upsell_variant.valid?).to eq(false)
        expect(@upsell_variant.errors.full_messages.first).to eq("The selected variant and the offered variant must belong to the upsell's offered product.")
      end
    end
  end

  context "when the variants belong to the upsell's offered product" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller)
      @upsell = create(:upsell, product: @product, seller: @seller)
      @upsell_variant = build(:upsell_variant, upsell: @upsell, selected_variant: create(:variant, variant_category: create(:variant_category, link: @product)), offered_variant: create(:variant, variant_category: create(:variant_category, link: @product)))
    end

    it "doesn't add an error" do
      expect(@upsell_variant.valid?).to eq(true)
    end
  end
end
