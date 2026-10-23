# frozen_string_literal: true

require "spec_helper"

describe "mcp_connector one-click unsubscribe", type: :request do
  include ActiveJob::TestHelper

  let(:creator) { create(:product, user: create(:user, email: "mcp-unsub@example.com")).user }

  before do
    host! DOMAIN
    ActionMailer::Base.deliveries.clear
    FeatureAnnouncementSubscription.update_from_settings!(creator, subscribed: true, rendered_version: 0)
  end

  it "stops a queued message after the recipient uses the link from an earlier render" do
    rendered = FeatureAnnouncementMailer.announcement(campaign: "mcp_connector", user_id: creator.id, email: creator.email)
    link = URI.parse(rendered["List-Unsubscribe"].value.delete_prefix("<").delete_suffix(">")).path
    FeatureAnnouncementMailer.announcement(campaign: "mcp_connector", user_id: creator.id, email: creator.email).deliver_later(queue: "low")

    post link, params: "List-Unsubscribe=One-Click", headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    perform_enqueued_jobs

    expect(response).to have_http_status(:ok)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(FeatureAnnouncementDelivery.find_by!(campaign: "mcp_connector", user_id: creator.id).attributes.slice("state", "reason"))
      .to eq("state" => "skipped", "reason" => "not_subscribed")
  end
end
