# frozen_string_literal: true

require "spec_helper"

describe "Variant tier-specific fixed duration functionality" do
  let(:membership_product) { create(:product, is_tiered_membership: true, is_recurring_billing: true) }
  let(:variant_category) { create(:variant_category, link: membership_product) }
  
  describe "#recurrence_price_values" do
    context "with tier-specific fixed durations" do
      let(:tier1) { create(:variant, name: "Basic", variant_category: variant_category) }
      let(:tier2) { create(:variant, name: "Premium", variant_category: variant_category) }
      
      before do
        create(:variant_price, 
               variant: tier1, 
               recurrence: "monthly", 
               price_cents: 1000,
               fixed_duration_months: 12)
        
        create(:variant_price,
               variant: tier2,
               recurrence: "monthly", 
               price_cents: 2000,
               fixed_duration_months: 24)
      end

      it "returns tier-specific duration information for customer display" do
        tier1_values = tier1.recurrence_price_values(for_edit: false)
        tier2_values = tier2.recurrence_price_values(for_edit: false)

        expect(tier1_values["monthly"][:fixed_duration_months]).to eq(12)
        expect(tier1_values["monthly"][:duration_display]).to eq("12 months")
        
        expect(tier2_values["monthly"][:fixed_duration_months]).to eq(24)
        expect(tier2_values["monthly"][:duration_display]).to eq("24 months")
      end

      it "returns tier-specific duration information for admin edit" do
        tier1_values = tier1.recurrence_price_values(for_edit: true)
        tier2_values = tier2.recurrence_price_values(for_edit: true)

        expect(tier1_values["monthly"][:fixed_duration_months]).to eq(12)
        expect(tier1_values["monthly"][:duration_display]).to eq("12 months")
        
        expect(tier2_values["monthly"][:fixed_duration_months]).to eq(24)
        expect(tier2_values["monthly"][:duration_display]).to eq("24 months")
      end
    end

    context "without fixed durations" do
      let(:ongoing_tier) { create(:variant, name: "Ongoing", variant_category: variant_category) }
      
      before do
        create(:variant_price, 
               variant: ongoing_tier, 
               recurrence: "monthly", 
               price_cents: 1000)
      end

      it "does not include duration information for ongoing subscriptions" do
        values = ongoing_tier.recurrence_price_values(for_edit: false)
        
        expect(values["monthly"]).not_to have_key(:fixed_duration_months)
        expect(values["monthly"]).not_to have_key(:duration_display)
      end
    end
  end

  describe "#has_fixed_duration_pricing?" do
    let(:variant) { create(:variant, variant_category: variant_category) }

    context "when variant has fixed duration prices" do
      before do
        create(:variant_price, 
               variant: variant, 
               recurrence: "monthly",
               fixed_duration_months: 12)
      end

      it "returns true" do
        expect(variant.has_fixed_duration_pricing?).to be true
      end
    end

    context "when variant has no fixed duration prices" do
      before do
        create(:variant_price, variant: variant, recurrence: "monthly")
      end

      it "returns false" do
        expect(variant.has_fixed_duration_pricing?).to be false
      end
    end
  end

  describe "#duration_for_recurrence" do
    let(:variant) { create(:variant, variant_category: variant_category) }

    context "when recurrence has fixed duration" do
      before do
        create(:variant_price, 
               variant: variant, 
               recurrence: "monthly",
               fixed_duration_months: 18)
      end

      it "returns the duration in months" do
        expect(variant.duration_for_recurrence("monthly")).to eq(18)
      end
    end

    context "when recurrence has no fixed duration" do
      before do
        create(:variant_price, variant: variant, recurrence: "monthly")
      end

      it "returns nil" do
        expect(variant.duration_for_recurrence("monthly")).to be_nil
      end
    end
  end

  describe "#duration_display_for_recurrence" do
    let(:variant) { create(:variant, variant_category: variant_category) }

    context "when recurrence has fixed duration" do
      before do
        create(:variant_price, 
               variant: variant, 
               recurrence: "monthly",
               fixed_duration_months: 18)
      end

      it "returns the duration display" do
        expect(variant.duration_display_for_recurrence("monthly")).to eq("18 months")
      end
    end

    context "when recurrence has no fixed duration" do
      before do
        create(:variant_price, variant: variant, recurrence: "monthly")
      end

      it "returns 'Ongoing'" do
        expect(variant.duration_display_for_recurrence("monthly")).to eq("Ongoing")
      end
    end
  end
end