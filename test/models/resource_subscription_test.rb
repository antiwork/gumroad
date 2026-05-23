# frozen_string_literal: true

require "test_helper"

class ResourceSubscriptionTest < ActiveSupport::TestCase
  self.described_class = ResourceSubscription



  context_ ResourceSubscription do
    before do
      @user = create(:user)
    end

  context_ "#assign_content_type_to_json_for_zapier" do
  test "sets content_type to application/json for Zapier subscriptions" do
        resource_subscription = create(:resource_subscription, post_url: "https://hooks.zapier.com/sample", user: @user)
        expect(resource_subscription.content_type).to eq "application/json"
      end

  test "doesn't overwrite the default content_type application/x-www-form-urlencoded for non-Zapier subscriptions" do
        resource_subscription = create(:resource_subscription, post_url: "https://hooks.example.com/sample", user: @user)
        expect(resource_subscription.content_type).to eq "application/x-www-form-urlencoded"
      end
    end
  end
end
