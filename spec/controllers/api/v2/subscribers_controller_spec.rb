# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::SubscribersController do
  before do
    @seller = create(:user)
    @subscriber = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:subscription_product, user: @seller, subscription_duration: "monthly")
    @subscription = create(:subscription, link: @product, user: @subscriber)
    create(:membership_purchase, link: @product, subscription: @subscription)
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = { link_id: @product.external_id }
    end

    describe "when logged in with sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          subscribers: @product.subscriptions.as_json
        }.as_json(api_scopes: ["view_public"]))
      end

      context "when a subscriber does not have a user account" do
        it "filters subscribers by email if one is specified" do
          expected_subscription = create(:subscription_without_user, link: @product, email: "non_gumroad_user@example.com")

          get @action, params: @params.merge(email: "  #{expected_subscription.email}  ")

          expect(response.parsed_body).to eq({
            success: true,
            subscribers: [expected_subscription.as_json]
          }.as_json)
        end
      end

      it "does not return subscribers for another user's product" do
        new_token = create("doorkeeper/access_token", application: @app, resource_owner_id: @subscriber.id, scopes: "view_sales")
        @params.merge!(access_token: new_token.token)
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "The product was not found."
        }.as_json)
      end

      context "for a tiered membership" do
        it "returns the right response" do
          product = create(:membership_product, user: @seller)
          subscription = create(:subscription, link: product)
          create(:membership_purchase, link: @product, subscription:)

          get @action, params: @params.merge!(link_id: product.external_id)
          expect(response.parsed_body).to eq({
            success: true,
            subscribers: product.subscriptions.as_json
          }.as_json(api_scopes: ["view_public"]))
        end
      end

      context "with pagination" do
        before do
          stub_const("#{described_class}::RESULTS_PER_PAGE", 1)
          @subscription_2 = create(:subscription, link: @product, user: @subscriber)
          create(:membership_purchase, link: @product, subscription: @subscription_2)
          @params.merge!(paginated: "true")
        end

        it "returns a link to the next page if there are more than the limit of sales" do
          expected_subscribers = @product.subscriptions.order(created_at: :desc, id: :desc).to_a

          get @action, params: @params
          expected_page_key = "#{expected_subscribers[0].created_at.to_fs(:usec)}-#{ObfuscateIds.encrypt_numeric(expected_subscribers[0].id)}"
          expect(response.parsed_body).to equal_with_indifferent_access({
            success: true,
            subscribers: [expected_subscribers[0].as_json],
            next_page_url: "/v2/products/#{@product.external_id}/subscribers.json?page_key=#{expected_page_key}&paginated=true",
            next_page_key: expected_page_key,
          }.as_json)
          total_found = response.parsed_body["subscribers"].size

          @params[:page_key] = response.parsed_body["next_page_key"]
          get :index, params: @params

          expect(response.parsed_body).to eq({
            success: true,
            subscribers: [expected_subscribers[1].as_json]
          }.as_json)


          total_found += response.parsed_body["subscribers"].size
          expect(total_found).to eq(expected_subscribers.size)
        end
      end
    end

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "the response is 403 forbidden for incorrect scope" do
        get @action, params: @params
        expect(response.code).to eq "403"
      end
    end
  end

  describe "GET 'show'" do
    before do
      @product = create(:product, user: @seller)
      @action = :show
      @params = { id: @subscription.external_id }
    end

    describe "when logged in with sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
        @params.merge!(access_token: @token.token)
      end

      it "returns a subscriber that belongs to the seller's product" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          subscriber: @subscription.as_json
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "does not return a subscriber that does not belong to the seller's product" do
        subscription_by_seller = create(
          :subscription,
          link: create(:membership_product, user: @subscriber, subscription_duration: "monthly"),
          user: @subscriber
        )
        @params.merge!(id: subscription_by_seller.id)
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "The subscriber was not found."
        }.as_json)
      end
    end

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "the response is 403 forbidden for incorrect scope" do
        get @action, params: @params
        expect(response.code).to eq "403"
      end
    end
  end
end
