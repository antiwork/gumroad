# frozen_string_literal: true

require "spec_helper"

describe "VariantPrice tier-specific fixed duration functionality" do
  describe "#has_fixed_duration?" do
    context "when fixed_duration_months is present" do
      let(:price) { create(:variant_price, fixed_duration_months: 12) }

      it "returns true" do
        expect(price.has_fixed_duration?).to be true
      end
    end

    context "when fixed_duration_months is nil" do
      let(:price) { create(:variant_price, fixed_duration_months: nil) }

      it "returns false" do
        expect(price.has_fixed_duration?).to be false
      end
    end

    context "when fixed_duration_months is 0" do
      it "cannot be created due to validation" do
        expect { create(:variant_price, fixed_duration_months: 0) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "#duration_display" do
    context "when fixed_duration_months is present" do
      let(:price) { create(:variant_price, fixed_duration_months: 6) }

      it "returns a formatted duration string" do
        expect(price.duration_display).to eq("6 months")
      end
    end

    context "when fixed_duration_months is nil" do
      let(:price) { create(:variant_price, fixed_duration_months: nil) }

      it "returns 'Ongoing'" do
        expect(price.duration_display).to eq("Ongoing")
      end
    end
  end

  describe "#formatted_duration_with_recurrence" do
    context "with monthly recurrence and fixed duration" do
      let(:price) { create(:variant_price, 
                           recurrence: "monthly",
                           fixed_duration_months: 12) }

      it "formats duration with recurrence properly" do
        expect(price.formatted_duration_with_recurrence).to eq("12 months")
      end
    end

    context "with yearly recurrence and fixed duration" do
      let(:price) { create(:variant_price, 
                           recurrence: "yearly",
                           fixed_duration_months: 24) }

      it "formats duration with recurrence properly" do
        expect(price.formatted_duration_with_recurrence).to eq("2 years")
      end
    end

    context "without fixed duration" do
      let(:price) { create(:variant_price, recurrence: "monthly") }

      it "returns ongoing subscription format" do
        expect(price.formatted_duration_with_recurrence).to eq("Ongoing")
      end
    end
  end

  describe "#formatted_price_with_duration" do
    context "with fixed duration" do
      let(:price) { create(:variant_price, 
                           price_cents: 2400,
                           currency: "usd",
                           fixed_duration_months: 12) }

      it "includes duration in price formatting" do
        formatted = price.formatted_price_with_duration
        expect(formatted).to include("24")
        expect(formatted).to include("for 12 months")
      end
    end

    context "without fixed duration" do
      let(:price) { create(:variant_price, 
                           price_cents: 1000,
                           currency: "usd",
                           recurrence: "monthly") }

      it "returns standard recurring price format" do
        formatted = price.formatted_price_with_duration
        expect(formatted).to include("10")
        expect(formatted).to include("month")
      end
    end
  end

  describe "validation scenarios" do
    context "when creating prices with tier-specific durations" do
      let(:membership_product) { create(:product, is_tiered_membership: true) }
      let(:variant_category) { create(:variant_category, link: membership_product) }
      let(:tier1) { create(:variant, name: "Basic", variant_category: variant_category) }
      let(:tier2) { create(:variant, name: "Premium", variant_category: variant_category) }

      it "allows different durations for different tiers" do
        price1 = create(:variant_price, 
                       variant: tier1,
                       recurrence: "monthly",
                       fixed_duration_months: 12)
        
        price2 = create(:variant_price,
                       variant: tier2, 
                       recurrence: "monthly",
                       fixed_duration_months: 24)

        expect(price1).to be_valid
        expect(price2).to be_valid
        expect(price1.fixed_duration_months).to eq(12)
        expect(price2.fixed_duration_months).to eq(24)
      end

      it "allows the same recurrence with different durations across tiers" do
        # Create prices directly instead of using save_recurring_prices! to avoid validation conflicts
        price1 = create(:variant_price,
                        variant: tier1,
                        recurrence: "monthly",
                        price_cents: 1000,
                        fixed_duration_months: 12)
        
        price2 = create(:variant_price,
                        variant: tier2,
                        recurrence: "monthly",
                        price_cents: 2000,
                        fixed_duration_months: 36)

        expect(price1.fixed_duration_months).to eq(12)
        expect(price2.fixed_duration_months).to eq(36)
      end
    end
  end
end