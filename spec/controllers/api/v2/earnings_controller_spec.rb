# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::EarningsController do
  let(:seller) { create(:user, created_at: Time.new(2022, 1, 1)) }
  let(:app) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_tax_data") }

  before do
    travel_to Time.new(2026, 4, 15)
    create(:user_compliance_info, user: seller)
    Feature.activate_user(:tax_center, seller)
  end

  describe "GET 'show'" do
    before do
      @action = :show
      @params = { year: 2025 }
    end

    it_behaves_like "authorized oauth v1 api method"

    context "when authenticated with view_tax_data scope" do
      before do
        @params.merge!(format: :json, access_token: token.token)
      end

      it "returns 403 with empty body when token is missing the view_tax_data scope" do
        other_token = create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_sales")
        get :show, params: @params.merge(access_token: other_token.token)

        expect(response.status).to eq(403)
        expect(response.body.strip).to be_empty
      end

      it "returns 403 when tax_center is not enabled" do
        Feature.deactivate_user(:tax_center, seller)
        get :show, params: @params

        expect(response.status).to eq(403)
        expect(response.parsed_body).to eq({
          success: false,
          message: "Tax center is not enabled for this account."
        }.as_json)
      end

      it "returns zeroed totals for a valid year with no sales" do
        get :show, params: @params

        expect(response).to be_successful
        expect(response.parsed_body).to eq({
          success: true,
          year: 2025,
          currency: "usd",
          gross_cents: 0,
          fees_cents: 0,
          taxes_cents: 0,
          affiliate_credit_cents: 0,
          net_cents: 0
        }.as_json)
      end

      it "returns aggregated earnings in cents" do
        product = create(:product, user: seller, price_cents: 1000)
        create(:purchase, :with_custom_fee, link: product, created_at: Time.new(2025, 3, 15), fee_cents: 100, tax_cents: 50, gumroad_tax_cents: 30)
        create(:purchase, :with_custom_fee, link: product, created_at: Time.new(2025, 6, 20), fee_cents: 120, gumroad_tax_cents: 25).tap do |p|
          p.update!(affiliate_credit_cents: 150)
        end
        create(:purchase, :with_custom_fee, link: product, created_at: Time.new(2025, 9, 10), fee_cents: 80, tax_cents: 75)

        # Fully refunded — excluded.
        create(:purchase, link: product, created_at: Time.new(2025, 4, 1), price_cents: 5000).tap do |p|
          p.update!(stripe_refunded: true)
          create(:refund, purchase: p, amount_cents: p.price_cents)
        end

        # Outside year — excluded.
        create(:purchase, link: product, created_at: Time.new(2024, 12, 31))

        get :show, params: @params

        expect(response).to be_successful
        expect(response.parsed_body).to eq({
          success: true,
          year: 2025,
          currency: "usd",
          gross_cents: 3055,
          fees_cents: 300,
          taxes_cents: 180,
          affiliate_credit_cents: 150,
          net_cents: 2425
        }.as_json)
      end

      it "returns 404 when the year is outside the available range" do
        get :show, params: @params.merge(year: 2019)

        expect(response.status).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "Earnings are not available for 2019."
        }.as_json)
      end

      it "returns 404 when year is a non-scalar param" do
        get :show, params: @params.merge(year: ["2025"])

        expect(response.status).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "Earnings are not available for the requested year."
        }.as_json)
      end

      it "returns 404 when the year is the current year" do
        get :show, params: @params.merge(year: 2026)

        expect(response.status).to eq(404)
      end

      it "returns 404 when the year is before the seller account-creation year" do
        get :show, params: @params.merge(year: 2021)

        expect(response.status).to eq(404)
      end

      it "does not include sales from other sellers" do
        product = create(:product, user: seller, price_cents: 1000)
        other_seller = create(:user, created_at: Time.new(2022, 1, 1))
        other_product = create(:product, user: other_seller, price_cents: 1000)

        create(:purchase, :with_custom_fee, link: product, created_at: Time.new(2025, 3, 15), fee_cents: 100)
        create(:purchase, :with_custom_fee, link: other_product, created_at: Time.new(2025, 3, 15), fee_cents: 999)

        get :show, params: @params

        expect(response.parsed_body["fees_cents"]).to eq(100)
      end
    end
  end
end
