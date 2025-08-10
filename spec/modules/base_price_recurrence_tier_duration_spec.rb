# frozen_string_literal: true

require "spec_helper"

describe "BasePrice::Recurrence tier-specific duration functionality" do
  describe "PERMITTED_PARAMS" do
    it "includes fixed_duration_months for all recurrences" do
      BasePrice::Recurrence::ALLOWED_RECURRENCES.each do |recurrence|
        permitted = BasePrice::Recurrence::PERMITTED_PARAMS[recurrence.to_sym]
        
        expect(permitted).to include(:fixed_duration_months)
      end
    end

    it "maintains backward compatibility with existing price fields" do
      BasePrice::Recurrence::ALLOWED_RECURRENCES.each do |recurrence|
        permitted = BasePrice::Recurrence::PERMITTED_PARAMS[recurrence.to_sym]
        
        expect(permitted).to include(:enabled)
        expect(permitted).to include(:price)
        expect(permitted).to include(:price_cents)
        expect(permitted).to include(:suggested_price)
        expect(permitted).to include(:suggested_price_cents)
      end
    end

    context "when processing variant params through Rails controller" do
      let(:membership_product) { create(:product, is_tiered_membership: true) }
      let(:variant_category) { create(:variant_category, link: membership_product) }

      it "allows duration fields to pass through permitted params" do
        # Simulate controller params with tier-specific durations
        variant_params = {
          variants: [
            {
              name: "Basic Tier",
              price_difference_cents: 1000,
              recurrence_price_values: {
                monthly: {
                  enabled: "1",
                  price_cents: "1000",
                  fixed_duration_months: "12"
                }
              }
            }
          ]
        }

        # Test that these would be permitted through strong parameters
        # This simulates what happens in LinksController#product_permitted_params
        permitted_recurrence_params = BasePrice::Recurrence::PERMITTED_PARAMS

        expect(permitted_recurrence_params[:monthly]).to include(:fixed_duration_months)
      end
    end
  end

  describe "recurrence formatting with fixed durations" do
    let(:membership_product) { create(:product, is_tiered_membership: true) }
    let(:variant_category) { create(:variant_category, link: membership_product) }
    let(:variant) { create(:variant, variant_category: variant_category) }

    context "when price has fixed duration" do
      let(:price) { create(:variant_price, 
                          variant: variant,
                          recurrence: "monthly",
                          fixed_duration_months: 12) }

      it "preserves recurrence information for internal calculations" do
        expect(BasePrice::Recurrence.number_of_months_in_recurrence("monthly")).to eq(1)
        expect(BasePrice::Recurrence.seconds_in_recurrence("monthly")).to eq(1.month)
      end

      it "uses fixed duration for display purposes" do
        expect(price.fixed_duration_months).to eq(12)
        expect(price.recurrence).to eq("monthly")
      end
    end

    context "integration with recurrence indicators" do
      include BasePrice::Recurrence

      it "maintains existing recurrence indicator methods" do
        expect(recurrence_long_indicator("monthly")).to eq("a month")
        expect(recurrence_short_indicator("monthly")).to eq("/ month")
        expect(single_period_indicator("monthly")).to eq("1-month")
      end

      it "works with all allowed recurrences" do
        BasePrice::Recurrence::ALLOWED_RECURRENCES.each do |recurrence|
          expect { recurrence_long_indicator(recurrence) }.not_to raise_error
          expect { recurrence_short_indicator(recurrence) }.not_to raise_error
          expect { single_period_indicator(recurrence) }.not_to raise_error
        end
      end
    end
  end

end