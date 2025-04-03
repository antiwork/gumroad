# frozen_string_literal: true

require "spec_helper"

RSpec.describe Payouts::ExportablesController, type: :controller do
  let(:seller) { create(:named_seller) }

  before do
    sign_in seller
  end

  describe "GET #index" do
    context "when the seller has payouts" do
      let!(:payouts_2021) { create_list(:payment_completed, 2, user: seller, created_at: Time.zone.local(2021, 1, 1)) }
      let!(:payouts_2022) { create_list(:payment_completed, 3, user: seller, created_at: Time.zone.local(2022, 1, 1)) }

      it "returns data with the most recent year if no year is provided" do
        get :index

        expect(response.parsed_body["years_with_payouts"]).to contain_exactly(2021, 2022)
        expect(response.parsed_body["selected_year"]).to eq(2022)
        expect(response.parsed_body["payouts_in_selected_year"]).to contain_exactly(
          {
            id: payouts_2022.first.external_id,
            date_formatted: "January 1st, 2022"
          },
          {
            id: payouts_2022.second.external_id,
            date_formatted: "January 1st, 2022"
          },
          {
            id: payouts_2022.third.external_id,
            date_formatted: "January 1st, 2022"
          }
        )
      end

      it "returns data with the most recent year if user does not have payouts in the selected year" do
        get :index, params: { year: 2025 }

        expect(response.parsed_body["years_with_payouts"]).to contain_exactly(2021, 2022)
        expect(response.parsed_body["selected_year"]).to eq(2022)
        expect(response.parsed_body["payouts_in_selected_year"]).to contain_exactly(
          {
            id: payouts_2022.first.external_id,
            date_formatted: "January 1st, 2022"
          },
          {
            id: payouts_2022.second.external_id,
            date_formatted: "January 1st, 2022"
          },
          {
            id: payouts_2022.third.external_id,
            date_formatted: "January 1st, 2022"
          }
        )
      end

      it "returns payouts for the selected year" do
        get :index, params: { year: 2021 }

        expect(response.parsed_body["selected_year"]).to eq(2021)
        expect(response.parsed_body["payouts_in_selected_year"].length).to eq(2)
        expect(response.parsed_body["payouts_in_selected_year"]).to contain_exactly(
          {
            id: payouts_2021.first.external_id,
            date_formatted: "January 1st, 2021"
          },
          {
            id: payouts_2021.second.external_id,
            date_formatted: "January 1st, 2021"
          }
        )
      end
    end

    context "when the seller has no payouts" do
      it "populates the year-related attributes with the current year" do
        current_year = Time.zone.now.year
        get :index

        expect(response.parsed_body["years_with_payouts"]).to contain_exactly(current_year)
        expect(response.parsed_body["selected_year"]).to eq(current_year)
        expect(response.parsed_body["payouts_in_selected_year"]).to eq([])
      end
    end

    context "when there are payments that are not completed or not displayable" do
      before do
        # Create completed payments that should be included
        create_list(:payment_completed, 2, user: seller, created_at: Time.zone.local(2022, 1, 1))

        # Create payments with other states that should be excluded
        create(:payment, user: seller, state: "processing", created_at: Time.zone.local(2022, 2, 1))
        create(:payment, user: seller, state: "failed", created_at: Time.zone.local(2022, 3, 1))

        # Create a payment before the OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE
        too_old_to_display = PayoutsHelper::OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE - 1.year
        create(:payment_completed, user: seller, created_at: too_old_to_display)
      end

      it "only returns data that are both completed and displayable" do
        get :index

        expect(response.parsed_body["years_with_payouts"]).to contain_exactly(2022)
        expect(response.parsed_body["selected_year"]).to eq(2022)
        expect(response.parsed_body["payouts_in_selected_year"].length).to eq(2)
      end
    end
  end
end
