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

  describe "tier-specific duration functionality" do
    let(:variant) { create(:variant) }
    let(:variant_price) { create(:variant_price, variant: variant, recurrence: "monthly") }

    describe "#tier_name" do
      it "returns variant name when available" do
        variant.update!(name: "Premium Tier")
        expect(variant_price.tier_name).to eq "Premium Tier"
      end

      it "returns 'Tier' when variant name is not available" do
        variant_price.variant = nil
        expect(variant_price.tier_name).to eq "Tier"
      end
    end

    describe "#formatted_price_with_duration" do
      before do
        variant_price.update!(
          price_cents: 4999,
          fixed_duration_months: 12,
          recurrence: "monthly"
        )
      end

      it "formats price with duration when fixed duration is set" do
        result = variant_price.formatted_price_with_duration
        expect(result).to include("49.99")
        expect(result).to include("month")
        expect(result).to include("12 months")
      end

      context "without fixed duration" do
        before { variant_price.update!(fixed_duration_months: nil) }

        it "formats price without duration information" do
          result = variant_price.formatted_price_with_duration
          expect(result).to include("49.99")
          expect(result).to include("month")
          expect(result).not_to include("12 months")
        end
      end
    end

    describe "#subscription_summary" do
      before do
        variant.update!(name: "Premium")
        variant_price.update!(
          price_cents: 2999,
          fixed_duration_months: 24,
          recurrence: "monthly"
        )
      end

      it "returns complete subscription summary" do
        summary = variant_price.subscription_summary
        expect(summary).to include("Premium")
        expect(summary).to include("29.99")
        expect(summary).to include("24 months")
      end
    end

    describe "duration validation" do
      context "when fixed duration is less than billing cycle" do
        it "adds validation error for yearly billing with 6 month duration" do
          variant_price.fixed_duration_months = 6
          variant_price.recurrence = "yearly"
          
          expect(variant_price).not_to be_valid
          expect(variant_price.errors[:fixed_duration_months]).to include(
            "must be at least 12 months for yearly billing"
          )
        end
      end

      context "when fixed duration matches or exceeds billing cycle" do
        it "validates successfully for yearly billing with 12 month duration" do
          variant_price.fixed_duration_months = 12
          variant_price.recurrence = "yearly"
          
          expect(variant_price).to be_valid
        end

        it "validates successfully for yearly billing with 24 month duration" do
          variant_price.fixed_duration_months = 24
          variant_price.recurrence = "yearly"
          
          expect(variant_price).to be_valid
        end
      end

      context "when no fixed duration is set" do
        it "validates successfully" do
          variant_price.fixed_duration_months = nil
          expect(variant_price).to be_valid
        end
      end
    end

    describe "inheritance from BasePrice" do
      let(:variant_price) { create(:variant_price, fixed_duration_months: 18, recurrence: "monthly") }

      it "inherits duration calculation methods" do
        expect(variant_price.charge_occurrence_count).to eq 18
        expect(variant_price.has_fixed_duration?).to be true
        expect(variant_price.duration_display).to eq "18 months"
      end
    end
  end
end
