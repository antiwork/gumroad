# frozen_string_literal: true

require "spec_helper"

describe User::PingNotification do
  describe "#send_test_ping" do
    before do
      @user = create(:user)
      @purchase = create(:purchase, seller: @user, link: create(:product, user: @user))
      @ping_params = @purchase.payload_for_ping_notification.merge(test: true)
    end

    context "when notification_content_type if application/json" do
      before do
        @user.update_attribute(:notification_content_type, Mime[:json])
      end

      it "sends JSON payload in test ping" do
        expect(HTTParty).to receive(:post).with("https://example.com", timeout: 5, body: @ping_params.to_json, headers: { "Content-Type" => "application/json" })

        expect do
          @user.send_test_ping("https://example.com")
        end.to_not raise_error
      end
    end

    context "when notification_content_type is application/x-www-form-urlencoded" do
      before do
        @user.update_attribute(:notification_content_type, Mime[:url_encoded_form])
      end

      it "sends form-encoded payload in test ping" do
        expect(HTTParty).to receive(:post).with("https://example.com", timeout: 5, body: @ping_params.deep_stringify_keys, headers: { "Content-Type" => "application/x-www-form-urlencoded" })

        expect do
          @user.send_test_ping("https://example.com")
        end.to_not raise_error
      end

      it "encodes brackets in the payload keys" do
        @purchase.purchase_custom_fields << build(:purchase_custom_field, name: "name [for field] [[]]!@#$%^&", value: "John")

        expect(HTTParty).to receive(:post) do |url, options|
          expect(url).to eq("https://example.com")
          expect(options[:timeout]).to eq(5)
          expect(options[:headers]).to include("Content-Type" => "application/x-www-form-urlencoded")

          expect(options[:body]).not_to include("name [for field] [[]]!@#$%^&" => "John")
          expect(options[:body]).not_to include("custom_fields" => { "name [for field] [[]]!@#$%^&" => "John" })
          expect(options[:body]).to include("name %5Bfor field%5D %5B%5B%5D%5D!@#$%^&" => "John")
          expect(options[:body]).to include("custom_fields" => { "name %5Bfor field%5D %5B%5B%5D%5D!@#$%^&" => "John" })
        end

        expect do
          @user.send_test_ping("https://example.com")
        end.to_not raise_error
      end
    end
  end

  describe "#urls_for_ping_notification" do
    it "contains notification_endpoint and notification_content_type for 'sale' resource if present" do
      user = create(:user)
      post_urls = user.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME)
      expect(post_urls).to match_array([])

      user.update_attribute(:notification_endpoint, "http://notification.com")
      post_urls = user.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME)
      expect(post_urls).to match_array([[user.notification_endpoint, user.notification_content_type]])
    end

    it "contains the post_urls and content_type for the respective resources based on input parameter" do
      user = create(:user, notification_endpoint: "http://notification.com")
      oauth_app = create(:oauth_application, owner: user)
      create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "view_sales")
      sale_resource_subscription = create(:resource_subscription, oauth_application: oauth_app, user:,
                                                                  post_url: "http://notification.com/sale")
      refunded_resource_subscription = create(:resource_subscription, oauth_application: oauth_app, user:,
                                                                      resource_name: ResourceSubscription::REFUNDED_RESOURCE_NAME,
                                                                      post_url: "http://notification.com/refund")
      cancelled_resource_subscription = create(:resource_subscription, oauth_application: oauth_app, user:,
                                                                       resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME,
                                                                       post_url: "http://notification.com/cancellation")

      sale_post_urls = user.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME)
      expect(sale_post_urls).to match_array([[sale_resource_subscription.post_url, sale_resource_subscription.content_type],
                                             [user.notification_endpoint, user.notification_content_type]])

      refunded_post_urls = user.urls_for_ping_notification(ResourceSubscription::REFUNDED_RESOURCE_NAME)
      expect(refunded_post_urls).to match_array([[refunded_resource_subscription.post_url, refunded_resource_subscription.content_type]])

      cancelled_post_urls = user.urls_for_ping_notification(ResourceSubscription::CANCELLED_RESOURCE_NAME)
      expect(cancelled_post_urls).to match_array([[cancelled_resource_subscription.post_url, cancelled_resource_subscription.content_type]])
    end

    it "does not contain URLs for resource subscriptions if the user revoked access to the application" do
      user = create(:user)
      oauth_app = create(:oauth_application, owner: user)
      token = create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "view_sales")
      sale_resource_subscription = create(:resource_subscription, oauth_application: oauth_app, user:)

      sale_post_urls = user.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME)
      expect(sale_post_urls).to match_array([[sale_resource_subscription.post_url, sale_resource_subscription.content_type]])

      token.update!(revoked_at: Time.current)

      sale_post_urls = user.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME)
      expect(sale_post_urls).to match_array([])
    end
  end
end
