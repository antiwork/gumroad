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

end
