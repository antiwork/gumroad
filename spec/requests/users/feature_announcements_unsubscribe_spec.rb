# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Feature announcement unsubscribe links", type: :request, inertia: true do
  let(:user) { create(:user, email: "creator@example.com") }
  let(:token) { FeatureAnnouncementSubscription.unsubscribe_token(user, user.email) }
  let(:url) { user_unsubscribe_feature_announcements_path(token) }

  before do
    host! DOMAIN
    create(:feature_announcement_campaign, :piracy_reports)
    FeatureAnnouncementSubscription.update_from_settings!(user, subscribed: true, rendered_version: 0)
  end

  def subscribed?
    FeatureAnnouncementSubscription.subscribed?(user)
  end

  # Taken from the rendered email so the test exercises the link recipients actually get.
  let(:emailed_url) do
    mail = FeatureAnnouncementMailer.announcement(campaign: "piracy_reports", user_id: user.id, email: user.email)
    URI.parse(mail["List-Unsubscribe"].value.delete_prefix("<").delete_suffix(">")).path
  end

  it "only shows a confirmation on GET, so link scanners change nothing" do
    3.times { get emailed_url }

    expect(response).to have_http_status(:ok)
    expect(inertia).to render_component("Users/FeatureAnnouncements/Unsubscribe")
    expect(inertia.props).to include(unsubscribed: false, unsubscribe_url: emailed_url)
    expect(subscribed?).to be(true)
    expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).not_to include("creator@example.com")
  end

  it "unsubscribes on an RFC 8058 one-click POST with no session or CSRF token" do
    expect(ActionController::Base.allow_forgery_protection).to be(true)

    post emailed_url, params: "List-Unsubscribe=One-Click", headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

    expect(response).to have_http_status(:ok)
    expect(inertia).to render_component("Users/FeatureAnnouncements/Unsubscribe")
    expect(inertia.props).to include(unsubscribed: true)
    expect(subscribed?).to be(false)
  end

  it "is idempotent" do
    3.times { post url }

    expect(response).to have_http_status(:ok)
    expect(FeatureAnnouncementSubscription.where(user_id: user.id).pluck(:subscribed, :version, :source)).to eq([[false, 2, "unsubscribe_link"]])
  end

  it "records an opt-out for a user who never subscribed" do
    FeatureAnnouncementSubscription.where(user_id: user.id).delete_all

    post url

    expect(response).to have_http_status(:ok)
    expect(FeatureAnnouncementSubscription.where(user_id: user.id).pluck(:subscribed)).to eq([false])
  end

  it "leaves the user's other email preferences unchanged" do
    expect { post url }.not_to change { user.reload.attributes.slice("flags", "weekly_notification") }
    expect(user.announcement_notification_enabled).to be(true)
  end

  it "rejects a tampered token" do
    post user_unsubscribe_feature_announcements_path("#{token}x")
    expect(response).to have_http_status(:not_found)

    get user_unsubscribe_feature_announcements_path(token.reverse)
    expect(response).to have_http_status(:not_found)
    expect(subscribed?).to be(true)
  end

  it "rejects tokens issued for other unsubscribe links" do
    post user_unsubscribe_feature_announcements_path(user.secure_external_id(scope: "email_unsubscribe"))
    expect(response).to have_http_status(:not_found)

    post user_unsubscribe_feature_announcements_path(user.secure_external_id(scope: Users::ReviewRemindersController::TOKEN_SCOPE))
    expect(response).to have_http_status(:not_found)
    expect(subscribed?).to be(true)
  end

  it "is not accepted as a token by the shared product_update unsubscribe link" do
    get user_unsubscribe_path(id: token, email_type: "product_update")

    expect(user.reload.announcement_notification_enabled).to be(true)
    expect(subscribed?).to be(true)
  end

  it "tells the provider to retry when the opt-out can't get its lock in time" do
    allow(FeatureAnnouncementSubscription).to receive(:unsubscribe!).and_raise(ActiveRecord::LockWaitTimeout)

    post url

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
  end
end
