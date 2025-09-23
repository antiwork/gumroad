# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::SalesController do
  before do
    @seller = create(:user)
    @purchaser = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, price_cents: 100_00)
    @purchase = create(:purchase, purchaser: @purchaser, link: @product)
    @purchase_by_seller = create(:purchase, purchaser: @seller, link: create(:product, user: @purchaser))

    # other purchases
    membership = create(:membership_product, :with_free_trial_enabled, user: @seller)
    @free_trial_purchase = create(:free_trial_membership_purchase, link: membership, seller: @seller)
    %w(
      failed
      gift_receiver_purchase_successful
      preorder_authorization_successful
      test_successful
    ).map do |purchase_state|
      create(:purchase, link: @product, seller: @seller, purchase_state:)
    end
  end

  describe "GET 'index'" do
    before do
      @params = {}
    end

    describe "when logged in with sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        travel_to(Time.current + 5.minutes) do
          get :index, params: @params
          sales_json = [@purchase.as_json(version: 2), @free_trial_purchase.as_json(version: 2)].map(&:as_json)

          expect(response.parsed_body.keys).to match_array ["success", "sales"]
          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["sales"]).to match_array sales_json
        end
      end

      it "returns a link to the next page if there are more than 10 sales" do
        per_page = Api::V2::SalesController::RESULTS_PER_PAGE
        create_list(:purchase, per_page, link: @product)
        expected_sales = @seller.sales.for_sales_api.order(created_at: :desc, id: :desc).to_a

        travel_to(Time.current + 5.minutes) do
          get :index, params: @params
          expected_page_key = "#{expected_sales[per_page - 1].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_sales[per_page - 1].id)}"
          expect(response.parsed_body).to include({
            success: true,
            sales: expected_sales.first(per_page).as_json(version: 2),
            next_page_url: "/v2/sales.json?page_key=#{expected_page_key}",
            next_page_key: expected_page_key,
          }.as_json)
          total_found = response.parsed_body["sales"].size

          @params[:page_key] = response.parsed_body["next_page_key"]
          get :index, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            sales: expected_sales[per_page..].as_json(version: 2)
          }.as_json)
          total_found += response.parsed_body["sales"].size
          expect(total_found).to eq(expected_sales.size)

          # It should also work in the same way with the deprecated `page` param:
          @params.delete(:page_key)
          @params[:page] = 1
          get :index, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            sales: expected_sales.first(per_page).as_json(version: 2),
            next_page_url: "/v2/sales.json?page_key=#{expected_page_key}",
            next_page_key: expected_page_key,
          }.as_json)
          total_found = response.parsed_body["sales"].size

          @params[:page] = 2
          get :index, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            sales: expected_sales[per_page..].as_json(version: 2)
          }.as_json)
          total_found += response.parsed_body["sales"].size
          expect(total_found).to eq(expected_sales.size)
        end
      end

      it "returns the correct link to the next pages from second page onwards" do
        per_page = Api::V2::SalesController::RESULTS_PER_PAGE
        create_list(:purchase, (per_page * 3), link: @product)
        expected_sales = @seller.sales.for_sales_api.order(created_at: :desc, id: :desc).to_a

        @params[:page_key] = "#{expected_sales[per_page].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_sales[per_page].id)}"
        get :index, params: @params

        expected_page_key = "#{expected_sales[per_page * 2].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_sales[per_page * 2].id)}"
        expected_next_page_url = "/v2/sales.json?page_key=#{expected_page_key}"

        expect(response.parsed_body["next_page_url"]).to eq expected_next_page_url
      end

      it "does not return sales outside of date range" do
        @params.merge!(after: 5.days.ago.strftime("%Y-%m-%d"), before: 2.days.ago.strftime("%Y-%m-%d"))
        create(:purchase, link: @product, created_at: 7.days.ago)
        in_range_purchase = create(:purchase, link: @product, created_at: 3.days.ago)
        get :index, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          sales: [in_range_purchase.as_json(version: 2)]
        }.as_json)
      end

      it "filters sales by email if one is specified" do
        create(:purchase, link: @product, created_at: 7.days.ago)
        create(:purchase, link: @product, created_at: 3.days.ago)
        expected_sale = create(:purchase, link: @product, created_at: 3.days.ago)

        @params.merge!(after: 5.days.ago.strftime("%Y-%m-%d"),
                       before: 2.days.ago.strftime("%Y-%m-%d"),
                       email: "  #{expected_sale.email}  ")
        get :index, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          sales: [expected_sale.as_json(version: 2)]
        }.as_json)
      end

      it "filters sales by order_id if one is specified" do
        create(:purchase, link: @product, created_at: 3.days.ago)
        expected_sale = create(:purchase, link: @product, created_at: 2.days.ago)

        @params.merge!(order_id: expected_sale.external_id_numeric)
        get :index, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          sales: [expected_sale.as_json(version: 2)]
        }.as_json)
      end

      it "returns a 400 error if date format is incorrect" do
        @params.merge!(after: "394293")
        get :index, params: @params
        expect(response.code).to eq "400"
        expect(response.parsed_body).to eq({
          status: 400,
          error: "Invalid date format provided in field 'after'. Dates must be in the format YYYY-MM-DD."
        }.as_json)
      end

      it "returns a 400 error if page number is invalid" do
        @params.merge!(page: "e3")
        get :index, params: @params
        expect(response.code).to eq "400"
        expect(response.parsed_body).to eq({
          status: 400,
          error: "Invalid page number. Page numbers start at 1."
        }.as_json)
      end

      it "filters sales by product if one is specified" do
        matching_product = create(:product, user: @seller)
        matching_purchase = create(:purchase, purchaser: @purchaser, link: matching_product)
        create(:purchase, purchaser: @purchaser, link: @product)

        travel(1.second) do
          get :index, params: @params.merge(product_id: matching_product.external_id)
        end
        expect(response.parsed_body).to eq({
          success: true,
          sales: [matching_purchase.as_json(version: 2)]
        }.as_json)
      end

      it "returns empty result set when filtered by non-existing product ID" do
        get :index, params: @params.merge(product_id: ObfuscateIds.encrypt(0))
        expect(response.parsed_body).to eq({
          success: true,
          sales: []
        }.as_json)
      end

      it "returns empty result set when filtered by non-existing purchase ID" do
        get :index, params: @params.merge(order_id: ObfuscateIds.decrypt_numeric(0))

        expect(response.parsed_body).to eq({
          success: true,
          sales: []
        }.as_json)
      end

      it "returns a 400 error if order_id ID cannot be decrypted" do
        get :index, params: @params.merge(order_id: "invalid base64")

        expect(response.code).to eq "400"
        expect(response.parsed_body).to eq({
          status: 400,
          error: "Invalid order ID."
        }.as_json)
      end

      it "returns the correct dispute information" do
        # We have a filter in the controller so the purchases for today are not added
        @params.merge!(before: 1.day.from_now)

        get :index, params: @params
        # Assert that the response has dispute_won and disputed = false
        sale_json = response.parsed_body["sales"].find { |s| s["id"] == @purchase.external_id }
        expect(sale_json).to include("disputed" => false, "dispute_won" => false)

        # Mark purchase as disputed
        @purchase.update!(chargeback_date: Time.current)
        get :index, params: @params
        sale_json = response.parsed_body["sales"].find { |s| s["id"] == @purchase.external_id }
        expect(sale_json).to include("disputed" => true, "dispute_won" => false)

        # Mark purchase as dispute reversed
        @purchase.update!(chargeback_reversed: true)
        get :index, params: @params
        sale_json = response.parsed_body["sales"].find { |s| s["id"] == @purchase.external_id }
        expect(sale_json).to include("disputed" => true, "dispute_won" => true)
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
      @product = create(:product, user: @seller)
      @params = { id: @purchase.external_id }
    end

    describe "when logged in with sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
        @params.merge!(access_token: @token.token)
      end

      it "returns a sale that belongs to the seller" do
        get :show, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          sale: @purchase.as_json(version: 2)
        }.as_json)
      end

      it "does not return a sale that does not belong to the seller" do
        @params.merge!(id: @purchase_by_seller.external_id)
        get :show, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "The sale was not found."
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

  describe "PUT 'mark_as_shipped'" do
    before do
      @product = create(:product, user: @seller)
      @params = { id: @purchase.external_id }
    end

    describe "when logged in with mark sales as shipped scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @seller.id,
                                                   scopes: "mark_sales_as_shipped")
        @params.merge!(access_token: @token.token)
      end

      it "marks shipment as shipped" do
        # There is no shipment yet
        expect(@purchase.shipment).to eq nil

        # Mark shipment as shipped via API
        put :mark_as_shipped, params: @params

        # Reload to get the shipment info
        @purchase.reload

        expect(@purchase.shipment.shipped?).to eq true
        expect(@purchase.shipment.tracking_url).to eq nil

        expect(response.parsed_body["sale"]["shipped"]).to eq true
        expect(response.parsed_body["sale"]["tracking_url"]).to eq nil

        expect(response.parsed_body).to eq({
          success: true,
          sale: @purchase.as_json(version: 2)
        }.as_json)
      end

      it "marks shipment as shipped and includes tracking url" do
        tracking_url = "sample-tracking-url"
        @params.merge!(tracking_url:)

        # There is no shipment yet
        expect(@purchase.shipment).to eq nil

        # Mark shipment as shipped via API
        put :mark_as_shipped, params: @params

        # Reload to get the shipment info
        @purchase.reload

        expect(@purchase.shipment.shipped?).to eq true
        expect(@purchase.shipment.tracking_url).to eq tracking_url

        expect(response.parsed_body["sale"]["shipped"]).to eq true
        expect(response.parsed_body["sale"]["tracking_url"]).to eq tracking_url

        expect(response.parsed_body).to eq({
          success: true,
          sale: @purchase.as_json(version: 2)
        }.as_json)
      end

      it "does not allow you to mark someone else's sale as shipped" do
        @params.merge!(id: @purchase_by_seller.external_id)
        put :mark_as_shipped, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "The sale was not found."
        }.as_json)
      end
    end

    describe "when logged in with view sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @seller.id,
                                                   scopes: "view_sales")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "the response is 403 forbidden for incorrect scope" do
        put :mark_as_shipped, params: @params
        expect(response.code).to eq "403"
      end
    end
  end

  describe "PUT 'refund'", :vcr do
    before do
      @purchase = create(:purchase_in_progress, purchaser: @purchaser, link: @product, chargeable: create(:chargeable))
      @purchase.process!
      @purchase.update_balance_and_mark_successful!
      @params = { id: @purchase.external_id }
      allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(1000_00)
    end

    describe "when logged in with refund_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @seller.id,
                                                   scopes: "refund_sales")
        @params.merge!(access_token: @token.token)
      end

      context "when request for a full refund" do
        it "refunds a sale fully" do
          expect(@purchase.price_cents).to eq 100_00
          expect(@purchase.refunded?).to be false

          put :refund, params: @params

          @purchase.reload
          expect(@purchase.refunded?).to be true
          expect(@purchase.refunds.last.refunding_user_id).to eq @product.user.id


          expect(response.parsed_body["sale"]["refunded"]).to eq true
          expect(response.parsed_body["sale"]["partially_refunded"]).to eq false
          expect(response.parsed_body["sale"]["amount_refundable_in_currency"]).to eq "0"

          expect(response.parsed_body).to eq({
            success: true,
            sale: @purchase.as_json(version: 2)
          }.as_json)
        end
      end

      context "when request for a partial refund" do
        it "refunds partially if refund amount is a fraction of the sale price" do
          expect(@purchase.price_cents).to eq 100_00
          expect(@purchase.refunded?).to be false

          put :refund, params: @params.merge(amount_cents: 50_50)

          @purchase.reload
          expect(@purchase.refunded?).to be false
          expect(@purchase.stripe_partially_refunded?).to be true


          expect(response.parsed_body["sale"]["refunded"]).to eq false
          expect(response.parsed_body["sale"]["partially_refunded"]).to eq true
          expect(response.parsed_body["sale"]["amount_refundable_in_currency"]).to eq "49.50"

          expect(response.parsed_body).to eq({
            success: true,
            sale: @purchase.as_json(version: 2)
          }.as_json)
        end

        it "refunds fully if refund amount matches the price of the sale" do
          expect(@purchase.price_cents).to eq 100_00
          expect(@purchase.refunded?).to be false

          put :refund, params: @params.merge(amount_cents: 100_00)

          @purchase.reload
          expect(@purchase.refunded?).to be true
          expect(@purchase.stripe_partially_refunded?).to be false


          expect(response.parsed_body["sale"]["refunded"]).to eq true
          expect(response.parsed_body["sale"]["partially_refunded"]).to eq false
          expect(response.parsed_body["sale"]["amount_refundable_in_currency"]).to eq "0"

          expect(response.parsed_body).to eq({
            success: true,
            sale: @purchase.as_json(version: 2)
          }.as_json)
        end

        it "correctly processes multiple partial refunds" do
          expect(@purchase.price_cents).to eq 100_00
          expect(@purchase.refunded?).to be false

          put :refund, params: @params.merge(amount_cents: 40_00)

          @purchase.reload
          expect(@purchase.refunded?).to be false
          expect(@purchase.stripe_partially_refunded?).to be true
          expect(@purchase.amount_refundable_cents).to eq 60_00

          put :refund, params: @params.merge(amount_cents: 40_00)

          @purchase.reload
          expect(@purchase.refunded?).to be false
          expect(@purchase.stripe_partially_refunded?).to be true
          expect(@purchase.amount_refundable_cents).to eq 20_00

          put :refund, params: @params.merge(amount_cents: 40_00)


          expect(response.parsed_body).to eq({
            success: false,
            message: "Refund amount cannot be greater than the purchase price."
          }.as_json)

          @purchase.reload
          expect(@purchase.amount_refundable_cents).to eq 20_00
        end

        it "does nothing if refund amount is negative" do
          expect(@purchase.refunded?).to be false

          put :refund, params: @params.merge(amount_cents: -1)

          @purchase.reload
          expect(@purchase.refunded?).to be false
          expect(@purchase.stripe_partially_refunded?).to be false


          expect(response.parsed_body).to eq({
            success: false,
            message: "The sale was unable to be modified."
          }.as_json)
        end

        it "does nothing if refund amount is too high" do
          expect(@purchase.price_cents).to eq 100_00
          expect(@purchase.refunded?).to be false

          put :refund, params: @params.merge(amount_cents: 100_00 + 1_00)

          @purchase.reload
          expect(@purchase.refunded?).to be false
          expect(@purchase.stripe_partially_refunded?).to be false


          expect(response.parsed_body).to eq({
            success: false,
            message: "Refund amount cannot be greater than the purchase price."
          }.as_json)
        end

        it "does nothing if refund amount is more than the available balance" do
          allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(99_99)

          expect(@purchase.price_cents).to eq 100_00
          expect(@purchase.refunded?).to be false

          put :refund, params: @params

          @purchase.reload
          expect(@purchase.refunded?).to be false
          expect(@purchase.stripe_partially_refunded?).to be false


          expect(response.parsed_body).to eq({
            success: false,
            message: "Your balance is insufficient to process this refund."
          }.as_json)
        end
      end

      it "does not refund an already refunded sale" do
        refunded_purchase = create(:refunded_purchase, purchaser: @purchaser, link: @product)

        put :refund, params: @params.merge(id: refunded_purchase.external_id)

        expect(response.parsed_body).to eq({
          success: false,
          message: "Purchase is already refunded."
        }.as_json)
      end

      it "does not refund a chargebacked sale" do
        disputed_purchase = create(:disputed_purchase, purchaser: @purchaser, link: @product)
        disputed_purchase.process!

        put :refund, params: @params.merge(id: disputed_purchase.external_id)

        expect(response.parsed_body).to eq({
          success: false,
          message: "The sale was unable to be modified."
        }.as_json)
      end

      it "does not refund if the sale is not successful" do
        in_progress_purchase = create(:purchase_in_progress, purchaser: @purchaser, link: @product)

        put :refund, params: @params.merge(id: in_progress_purchase.external_id)

        expect(response.parsed_body).to eq({
          success: false,
          message: "The sale was unable to be modified."
        }.as_json)
      end

      it "does not refund a free purchase" do
        free_purchase = create(:free_purchase, purchaser: @purchaser, link: @product)

        put :refund, params: @params.merge(id: free_purchase.external_id)

        expect(response.parsed_body).to eq({
          success: false,
          message: "The sale was unable to be modified."
        }.as_json)
      end

      it "does not allow to refund someone else's sale" do
        put :refund, params: @params.merge(id: @purchase_by_seller.external_id)
        expect(response.parsed_body).to eq({
          success: false,
          message: "The sale was not found."
        }.as_json)
      end
    end

    describe "when logged in with view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @seller.id,
                                                   scopes: "view_sales")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "the response is 403 forbidden for incorrect scope" do
        put :refund, params: @params
        expect(response.code).to eq "403"
      end
    end
  end
end
