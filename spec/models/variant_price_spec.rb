# frozen_string_literal: true

require "spec_helper"

describe VariantPrice do
  describe "associations" do
    it "belongs to a variant" do
      price = create(:variant_price)
      expect(price.variant).to be_a Variant
    end
  end

  describe "validations" do
    it "requires that the variant is present" do
      invalid_price = create(:variant_price)
      invalid_price.variant = nil
      expect(invalid_price).not_to be_valid
      expect(invalid_price.errors.full_messages).to include "Variant can't be blank"
    end

    it "requires that price_cents is present" do
      invalid_price = create(:variant_price)
      invalid_price.price_cents = nil
      expect(invalid_price).not_to be_valid
      expect(invalid_price.errors.full_messages).to include "Please provide a price for all selected payment options."
    end

    it "requires that currency is present" do
      invalid_price = create(:variant_price)
      invalid_price.currency = nil
      expect(invalid_price).not_to be_valid
      expect(invalid_price.errors.full_messages).to include "Currency can't be blank"
    end

    describe "recurrence validation" do
      context "when present" do
        it "must be one of the permitted recurrences" do
          BasePrice::Recurrence.all.each do |recurrence|
            expect(build(:variant_price, recurrence:)).to be_valid
          end

          invalid_price = build(:variant_price, recurrence: "whenever")

          expect(invalid_price).not_to be_valid
          expect(invalid_price.errors.full_messages).to include "Please provide a valid payment option."
        end
      end

      it "can be blank" do
        expect(build(:variant_price, recurrence: nil)).to be_valid
      end
    end
  end

  describe "is_default_recurrence?" do
    let(:product) { create(:membership_product, subscription_duration: "monthly") }

    it "returns true if the recurrence is the same as product's subscription duration" do
      price = create(:variant_price, variant: product.tiers.first, recurrence: "monthly")

      expect(price.is_default_recurrence?).to eq true
    end

    it "returns false if the recurrence is not the same as the product's subscription duration" do
      prices = [
        create(:variant_price, variant: product.tiers.first, recurrence: "yearly"),
        create(:variant_price, variant: product.tiers.first, recurrence: nil),
        create(:variant_price, recurrence: "monthly")
      ]

      prices.each do |price|
        expect(price.is_default_recurrence?).to eq false
      end
    end
  end

  describe "#price_formatted_without_symbol" do
    it "returns the formatted price without a symbol" do
      price = create(:variant_price, price_cents: 299)

      expect(price.price_formatted_without_symbol).to eq "2.99"
    end

    context "when price_cents is blank" do
      it "returns an empty string" do
        price = build(:variant_price, price_cents: nil)

        expect(price.price_formatted_without_symbol).to eq ""
      end
    end
  end

  describe "#suggested_price_formatted_without_symbol" do
    it "returns the formatted suggested price without a symbol" do
      price = create(:variant_price, suggested_price_cents: 299)

      expect(price.suggested_price_formatted_without_symbol).to eq "2.99"
    end

    context "when suggested_price_cents is blank" do
      it "returns nil" do
        price = build(:variant_price, suggested_price_cents: nil)

        expect(price.suggested_price_formatted_without_symbol).to eq nil
      end
    end
  end
end
