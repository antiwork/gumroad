# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::PayoutsController do
  before do
    stub_const("ObfuscateIds::CIPHER_KEY", "a" * 32)
    stub_const("ObfuscateIds::NUMERIC_CIPHER_KEY", 123456789)

    @seller = create(:user)
    @other_seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    # Ensure payments are created after the displayable date and with recent timestamps
    @payout = create(:payment_completed, user: @seller, amount_cents: 150_00, currency: "USD", created_at: 1.day.ago)
    @payout_by_other_seller = create(:payment_completed, user: @other_seller, amount_cents: 100_00, currency: "USD", created_at: 1.day.ago)
  end

  describe "GET 'index'" do
    before do
      @params = {}
    end

    describe "when logged in with view_payouts scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_payouts")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        travel_to(Time.current + 5.minutes) do
          get :index, params: @params
          payouts_json = [@payout.as_json].map(&:as_json)

          expect(response.parsed_body.keys).to match_array ["success", "payouts"]
          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["payouts"]).to match_array payouts_json
        end
      end

      it "returns a link to the next page if there are more than 10 payouts" do
        per_page = Api::V2::PayoutsController::RESULTS_PER_PAGE
        create_list(:payment_completed, per_page, user: @seller, created_at: 2.days.ago)
        expected_payouts = @seller.payments.displayable.order(created_at: :desc, id: :desc).to_a

        travel_to(Time.current + 5.minutes) do
          get :index, params: @params
          expected_page_key = "#{expected_payouts[per_page - 1].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_payouts[per_page - 1].id)}"
          expect(response.parsed_body).to include({
            success: true,
            payouts: expected_payouts.first(per_page).as_json,
            next_page_url: "/v2/payouts.json?page_key=#{expected_page_key}",
            next_page_key: expected_page_key,
          }.as_json)
          total_found = response.parsed_body["payouts"].size

          @params[:page_key] = response.parsed_body["next_page_key"]
          get :index, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            payouts: expected_payouts[per_page..].as_json
          }.as_json)
          total_found += response.parsed_body["payouts"].size
          expect(total_found).to eq(expected_payouts.size)
        end
      end

      it "returns the correct link to the next pages from second page onwards" do
        per_page = Api::V2::PayoutsController::RESULTS_PER_PAGE
        create_list(:payment_completed, (per_page * 3), user: @seller, created_at: 3.days.ago)
        expected_payouts = @seller.payments.displayable.order(created_at: :desc, id: :desc).to_a

        @params[:page_key] = "#{expected_payouts[per_page].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_payouts[per_page].id)}"
        get :index, params: @params

        expected_page_key = "#{expected_payouts[per_page * 2].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_payouts[per_page * 2].id)}"
        expected_next_page_url = "/v2/payouts.json?page_key=#{expected_page_key}"

        expect(response.parsed_body["next_page_url"]).to eq expected_next_page_url
      end

      it "does not return payouts outside of date range" do
        @params.merge!(after: 5.days.ago.strftime("%Y-%m-%d"), before: 2.days.ago.strftime("%Y-%m-%d"))
        create(:payment_completed, user: @seller, created_at: 7.days.ago)
        in_range_payout = create(:payment_completed, user: @seller, created_at: 3.days.ago)
        get :index, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          payouts: [in_range_payout.as_json]
        }.as_json)
      end

      it "returns a 400 error if after date format is incorrect" do
        @params.merge!(after: "394293")
        get :index, params: @params
        expect(response.code).to eq "400"
        expect(response.parsed_body).to eq({
          status: 400,
          error: "Invalid date format provided in field 'after'. Dates must be in the format YYYY-MM-DD."
        }.as_json)
      end

      it "returns a 400 error if before date format is incorrect" do
        @params.merge!(before: "invalid-date")
        get :index, params: @params
        expect(response.code).to eq "400"
        expect(response.parsed_body).to eq({
          status: 400,
          error: "Invalid date format provided in field 'before'. Dates must be in the format YYYY-MM-DD."
        }.as_json)
      end

      it "returns a 400 error if page_key is invalid" do
        @params.merge!(page_key: "invalid-page-key")
        get :index, params: @params
        expect(response.code).to eq "400"
        expect(response.parsed_body).to eq({
          status: 400,
          error: "Invalid page_key."
        }.as_json)
      end

      it "returns empty result set when no payouts exist in date range" do
        @params.merge!(after: 1.month.from_now.strftime("%Y-%m-%d"), before: 2.months.from_now.strftime("%Y-%m-%d"))
        get :index, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          payouts: []
        }.as_json)
      end

      it "only returns payouts for the current seller" do
        create(:payment_completed, user: @other_seller, created_at: 1.day.ago)
        create(:payment_completed, user: @seller, created_at: 2.hours.ago)

        get :index, params: @params

        payout_user_ids = response.parsed_body["payouts"].map { |p| Payment.find_by_external_id(p["id"]).user_id }
        expect(payout_user_ids).to all(eq(@seller.id))
        expect(response.parsed_body["payouts"].size).to eq 2 # @payout + seller_payout
      end

      it "filters by date correctly when both before and after are provided" do
        old_payout = create(:payment_completed, user: @seller, created_at: 10.days.ago)
        recent_payout = create(:payment_completed, user: @seller, created_at: 1.day.from_now)
        in_range_payout = create(:payment_completed, user: @seller, created_at: 3.days.ago)

        @params.merge!(after: 5.days.ago.strftime("%Y-%m-%d"), before: 2.days.ago.strftime("%Y-%m-%d"))
        get :index, params: @params

        payout_ids = response.parsed_body["payouts"].map { |p| p["id"] }
        expect(payout_ids).to include(in_range_payout.external_id)
        expect(payout_ids).not_to include(old_payout.external_id)
        expect(payout_ids).not_to include(recent_payout.external_id)
      end

      it "returns payouts in descending order by creation date" do
        oldest_payout = create(:payment_completed, user: @seller, created_at: 5.days.ago)
        newest_payout = create(:payment_completed, user: @seller, created_at: 1.day.ago)

        get :index, params: @params

        payout_ids = response.parsed_body["payouts"].map { |p| p["id"] }
        newest_index = payout_ids.index(newest_payout.external_id)
        oldest_index = payout_ids.index(oldest_payout.external_id)

        expect(newest_index).to be < oldest_index
      end

      describe "upcoming payout functionality" do
        before do
          # Set up seller with unpaid balance and payout capability
          create(:ach_account, user: @seller)
          create(:balance, user: @seller, amount_cents: 15_00, date: Date.parse("2025-09-10"), state: "unpaid")
          create(:bank, routing_number: "110000000", name: "Bank of America")
        end

        around do |example|
          # Exactly which days are in the upcoming payout may depend on the day of the week, so make sure it's consistent
          travel_to(Time.zone.parse("2025-09-15 12:00:00")) do
            example.run
          end
        end

        it "includes upcoming payout when no pagination and no date filtering" do
          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }

          expect(upcoming_payouts.length).to eq(1)
          upcoming_payout = upcoming_payouts.first
          expect(upcoming_payout["amount"]).to eq("15.00")
          expect(upcoming_payout["currency"]).to eq(Currency::USD)
          expect(upcoming_payout["status"]).to eq(@seller.payouts_status)
          expect(upcoming_payout["created_at"]).to eq(Time.zone.parse("2025-09-19").iso8601)
          expect(upcoming_payout["processed_at"]).to be_nil
        end

        it "indicates which payment processor will be used" do
          create(:user_compliance_info, user: @seller, country: "United Kingdom")
          @seller.active_bank_account&.destroy!
          @seller.update!(payment_address: "test@example.com")

          get :index, params: @params

          upcoming_payout = response.parsed_body["payouts"].first
          expect(upcoming_payout["id"]).to be_nil
          expect(upcoming_payout["payment_processor"]).to eq(PayoutProcessorType::PAYPAL)
          expect(upcoming_payout["bank_account_visual"]).to be_nil
          expect(upcoming_payout["paypal_email"]).to eq("test@example.com")

          bank_account = create(:uk_bank_account, user: @seller)
          @seller.update!(payment_address: nil)

          get :index, params: @params

          upcoming_payout = response.parsed_body["payouts"].first
          expect(upcoming_payout["id"]).to be_nil
          expect(upcoming_payout["payment_processor"]).to eq(PayoutProcessorType::STRIPE)
          expect(upcoming_payout["bank_account_visual"]).to eq(bank_account.account_number_visual)
          expect(upcoming_payout["paypal_email"]).to be_nil
        end

        it "includes upcoming payout when end_date is after current payout end date" do
          future_date = 1.month.from_now.strftime("%Y-%m-%d")
          @params.merge!(before: future_date)

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }

          expect(upcoming_payouts.length).to be >= 1
          expect(payouts.length).to be >= 1
        end

        it "does not include upcoming payout when include_upcoming is false" do
          @params.merge!(include_upcoming: "false")

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          expect(payouts).to be_all { |p| p["id"].present? }
        end

        it "does not include upcoming payout when using pagination" do
          @params.merge!(page_key: "#{Time.current.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(123)}")

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          payout_ids = payouts.map { |p| p["id"] }

          expect(payout_ids).not_to include(nil)
          expect(payouts.none? { |p| p["id"].nil? }).to be true
        end

        it "does not include upcoming payout when end_date is before current payout end date" do
          past_date = 1.week.ago.strftime("%Y-%m-%d")
          @params.merge!(before: past_date)

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          payout_ids = payouts.map { |p| p["id"] }

          expect(payout_ids).not_to include(nil)
          expect(payouts.none? { |p| p["id"].nil? }).to be true
        end

        it "positions upcoming payouts first in the results list" do
          older_payout = create(:payment_completed, user: @seller, created_at: 2.days.ago)

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }
          completed_payouts = payouts.select { |p| p["id"].present? }

          expect(upcoming_payouts.length).to eq(1)
          expect(payouts.first["id"]).to be_nil
          expect(completed_payouts.first["id"]).to eq(@payout.external_id)
          expect(completed_payouts.second["id"]).to eq(older_payout.external_id)
        end

        it "includes upcoming payout along with completed payouts up to page limit" do
          create_list(:payment_completed, 5, user: @seller, created_at: 1.week.ago)

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }
          completed_payouts = payouts.select { |p| p["id"].present? }

          expect(upcoming_payouts.length).to eq(1)
          expect(payouts.length).to be <= Api::V2::PayoutsController::RESULTS_PER_PAGE
          expect(completed_payouts.length).to eq([@seller.payments.displayable.count, Api::V2::PayoutsController::RESULTS_PER_PAGE - upcoming_payouts.length].min)
        end

        it "does not include upcoming payout when user has no unpaid balance" do
          @seller.balances.delete_all

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          payout_ids = payouts.map { |p| p["id"] }

          expect(payout_ids).not_to include(nil)
          expect(payouts.none? { |p| p["id"].nil? }).to be true
        end

        it "reflects current unpaid balance up to payout period end date" do
          create(:balance, user: @seller, amount_cents: 5_00, date: Date.parse("2025-09-08"), state: "unpaid")

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }

          expect(upcoming_payouts.length).to eq(1)
          upcoming_payout = upcoming_payouts.first
          expect(upcoming_payout["amount"]).to eq("20.00")
        end

        it "does not include upcoming payout when user is not payable due to minimum threshold" do
          @seller.balances.delete_all
          create(:balance, user: @seller, amount_cents: 5_00, date: Date.current, state: "unpaid") # Below $10 minimum

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          payout_ids = payouts.map { |p| p["id"] }

          expect(payout_ids).not_to include(nil)
          expect(payouts.none? { |p| p["id"].nil? }).to be true
        end

        it "includes upcoming payout with paused status when payouts are paused" do
          @seller.update!(payouts_paused_internally: true)

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }

          expect(upcoming_payouts.length).to eq(1)
          upcoming_payout = upcoming_payouts.first
          expect(upcoming_payout["status"]).to eq(User::PAYOUTS_STATUS_PAUSED)
        end

        it "includes upcoming payout when the date range includes it" do
          start_date = 1.week.ago.strftime("%Y-%m-%d")
          end_date = 1.week.from_now.strftime("%Y-%m-%d")

          @params.merge!(after: start_date, before: end_date)

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }

          expect(upcoming_payouts.length).to eq(1)
          upcoming_payout = upcoming_payouts.first
          expect(upcoming_payout["amount"]).to eq("15.00")
          expect(payouts.length).to eq(2)
        end

        it "handles multiple upcoming payouts correctly" do
          create(:balance, user: @seller, amount_cents: 20_00, date: Date.new(2025, 9, 15), state: "unpaid")

          get :index, params: @params

          payouts = response.parsed_body["payouts"]
          upcoming_payouts = payouts.select { |p| p["id"].nil? }

          expect(upcoming_payouts.length).to eq(2)

          expect(upcoming_payouts.first["amount"]).to eq("20.00")
          expect(upcoming_payouts.first["created_at"]).to eq(Time.zone.parse("2025-09-26").iso8601)
          expect(upcoming_payouts.second["amount"]).to eq("15.00")
          expect(upcoming_payouts.second["created_at"]).to eq(Time.zone.parse("2025-09-19").iso8601)
        end
      end
    end

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "the response is 403 forbidden for incorrect scope" do
        get :index, params: @params
        expect(response.code).to eq "403"
      end
    end
  end

  describe "GET 'show'" do
    before do
      @params = { id: @payout.external_id }
    end

    describe "when logged in with view_payouts scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_payouts")
        @params.merge!(access_token: @token.token)
      end

      it "returns a payout that belongs to the seller" do
        get :show, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          payout: @payout.as_json
        }.as_json)
      end

      context "when logged in with view_sales scope" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_payouts view_sales")
          @params.merge!(access_token: @token.token)
        end

        it "includes sales in the payout response when sales exist" do
          product = create(:product, user: @seller)
          balance = create(:balance, user: @seller)
          @payout.balances = [balance]
          @payout.save!

          successful_sale = create(:purchase, seller: @seller, link: product, purchase_success_balance: balance)

          get :show, params: @params

          response_payout = response.parsed_body["payout"]
          expect(response_payout).to have_key("sales")
          expect(response_payout["sales"]).to be_an(Array)
          expect(response_payout["sales"].length).to eq(1)

          sale_id = response_payout["sales"].first
          expect(sale_id).to be_a(String)
          expect(sale_id).to eq(successful_sale.external_id)
        end

        it "includes sales array even when no sales exist" do
          get :show, params: @params

          response_payout = response.parsed_body["payout"]
          expect(response_payout).to have_key("sales")
          expect(response_payout["sales"]).to be_an(Array)
          expect(response_payout["sales"]).to be_empty
        end
      end

      context "when logged in without view_sales scope" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_payouts")
          @params.merge!(access_token: @token.token)
        end

        it "excludes sales from the payout response" do
          product = create(:product, user: @seller)
          balance = create(:balance, user: @seller)
          @payout.balances = [balance]
          @payout.save!

          create(:purchase, seller: @seller, link: product, purchase_success_balance: balance)

          get :show, params: @params

          response_payout = response.parsed_body["payout"]
          expect(response_payout).not_to have_key("sales")
        end

        it "returns standard payout data without sales key" do
          get :show, params: @params

          response_payout = response.parsed_body["payout"]
          expected_keys = %w[id amount currency status created_at processed_at payment_processor bank_account_visual paypal_email]
          expect(response_payout.keys).to match_array(expected_keys)
          expect(response_payout).not_to have_key("sales")
        end
      end

      it "does not return a payout that does not belong to the seller" do
        @params.merge!(id: @payout_by_other_seller.external_id)
        get :show, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "The payout was not found."
        }.as_json)
      end

      it "returns 404 for non-existent payout" do
        @params.merge!(id: "non-existent-id")
        get :show, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "The payout was not found."
        }.as_json)
      end
    end

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "the response is 403 forbidden for incorrect scope" do
        get :show, params: @params
        expect(response.code).to eq "403"
      end
    end
  end
end
