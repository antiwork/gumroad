# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::ResourceSubscriptionsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
    @params = { access_token: @token.token }
  end

  describe "GET 'index'" do
    it "does not allow the request if the app doesn't have view_sales scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
      get :index, params: { access_token: token.token, resource_name: "sale" }
      expect(response.status).to eq(403)
    end

    it "requires a resource name" do
      get :index, params: { access_token: @token.token }
      expect(response.parsed_body["success"]).to be(false)
    end

    it "shows an empty list if there are no subscriptions" do
      get :index, params: { access_token: @token.token, resource_name: "sale" }

      expect(response.parsed_body["resource_subscriptions"].length).to eq(0)
    end

    it "shows a JSON representation of the live resource subscriptions" do
      put :create, params: @params.merge(resource_name: "sale", post_url: "https://example.com")
      put :create, params: @params.merge(resource_name: "sale", post_url: "https://postmebabyonemoretime.org")
      put :create, params: @params.merge(resource_name: "sale", post_url: "https://deadpostsociety.net")
      delete :destroy, params: @params.merge(id: response.parsed_body["resource_subscription"]["id"])

      get :index, params: { access_token: @token.token, resource_name: "sale" }

      expect(response.parsed_body["resource_subscriptions"].length).to eq(2)
      expect(response.parsed_body["resource_subscriptions"].first["post_url"]).to eq("https://example.com")
      expect(response.parsed_body["resource_subscriptions"].last["post_url"]).to eq("https://postmebabyonemoretime.org")
    end

    it "responds with an error JSON message for an invalid resource name" do
      get :index, params: { access_token: @token.token, resource_name: "invalid_resource" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("Valid resource_name parameter required")
    end
  end

  describe "PUT 'create'" do
    it "does not allow the subscription if the app doesn't have view_sales scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
      put(:create, params: { access_token: token.token, resource_name: "sale" })
      expect(response.response_code).to eq(403)
    end

    it "allows the subscription if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: "sale", post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::SALE_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows the subscription if the app has a post url which has localhost as part of its legitimate domain name" do
      put :create, params: @params.merge(resource_name: "sale", post_url: "http://learnaboutlocalhost.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::SALE_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://learnaboutlocalhost.com"
    end

    it "does not overwrite existing subscription" do
      put :create, params: @params.merge(resource_name: "sale", post_url: "http://example.com")
      put :create, params: @params.merge(resource_name: "sale", post_url: "http://postatmeb.ro")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 2
      expect(ResourceSubscription.first.post_url).to eq "http://example.com"
      expect(ResourceSubscription.last.post_url).to eq "http://postatmeb.ro"
    end

    it "allows subscription to 'refund' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::REFUNDED_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::REFUNDED_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows subscription to 'cancellation' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::CANCELLED_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows subscription to 'subscription_ended' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows subscription to 'subscription_restarted' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to eq(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows subscription to 'subscription_updated' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows subscription to 'dispute' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::DISPUTE_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::DISPUTE_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "allows subscription to 'dispute_won' resource if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: ResourceSubscription::DISPUTE_WON_RESOURCE_NAME, post_url: "http://example.com")

      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.count).to eq 1
      resource_subscription = ResourceSubscription.last
      expect(resource_subscription.user).to eq @user
      expect(resource_subscription.oauth_application).to eq @app
      expect(resource_subscription.resource_name).to eq ResourceSubscription::DISPUTE_WON_RESOURCE_NAME
      expect(resource_subscription.post_url).to eq "http://example.com"
    end

    it "responds with an error JSON message for an invalid resource name if the app has view_sales scope" do
      put :create, params: @params.merge(resource_name: "invalid_resource", post_url: "http://example.com")

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to include("Unable to subscribe")
    end

    it "responds with an error JSON message for a nil post URL" do
      put :create, params: @params.merge(resource_name: "sale")

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to include("Invalid post URL")
    end

    it "responds with an error JSON message for a post URL that can't be URI parsed" do
      put :create, params: @params.merge(resource_name: "sale", post_url: "foo bar")

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to include("Invalid post URL")
    end

    it "responds with an error JSON message for a non-HTTP post URL" do
      put :create, params: @params.merge(resource_name: "sale", post_url: "example.com")

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to include("Invalid post URL")
    end

    it "responds with an error JSON message for a localhost post URL" do
      ["http://127.0.0.1/path", "http://0.0.0.0/path", "http://localhost/path"].each do |post_url|
        put :create, params: @params.merge(resource_name: "sale", post_url:)

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to include("Invalid post URL")
      end
    end
  end

  describe "DELETE 'destroy'" do
    it "does not allow the deletion if the app doesn't own the subscription" do
      resource_subscription = create(:resource_subscription, user: @user, oauth_application: @app, resource_name: "sale")
      another_user = create(:user)
      another_app = create(:oauth_application, owner: another_user, name: "another application")
      another_token = create("doorkeeper/access_token", application: another_app, resource_owner_id: another_user.id, scopes: "view_sales")
      delete :destroy, params: { access_token: another_token.token, id: resource_subscription.external_id }
      expect(response.parsed_body["success"]).to be(false)
      expect(ResourceSubscription.last.deleted_at).to be(nil)
    end

    it "marks the subscription as deleted" do
      resource_subscription = create(:resource_subscription, user: @user, oauth_application: @app, resource_name: "sale")
      delete :destroy, params: { access_token: @token.token, id: resource_subscription.external_id }
      expect(response.parsed_body["success"]).to be(true)
      expect(ResourceSubscription.last.deleted_at).to be_present
    end
  end
end
