# frozen_string_literal: true

# Unsubscribe links from FeatureAnnouncementMailer. Both actions work without a session.
# GET only shows a confirmation, so link scanners that prefetch it change nothing. POST is
# the RFC 8058 one-click target, which mailbox providers send without a CSRF token.
class Users::FeatureAnnouncementsController < ApplicationController
  layout "inertia"

  skip_before_action :verify_authenticity_token, only: :unsubscribe
  before_action :set_private_link_headers
  before_action :set_user_from_token

  def confirm_unsubscribe
    render inertia: "Users/FeatureAnnouncements/Unsubscribe", props: {
      unsubscribe_url: user_unsubscribe_feature_announcements_path(params[:token]),
      unsubscribed: false,
    }
  end

  def unsubscribe
    FeatureAnnouncementSubscription.unsubscribe!(@user, source: "unsubscribe_link")
    render inertia: "Users/FeatureAnnouncements/Unsubscribe", props: { unsubscribe_url: nil, unsubscribed: true }
  rescue ActiveRecord::LockWaitTimeout
    response.headers["Retry-After"] = "60"
    head :service_unavailable
  end

  private
    def set_user_from_token
      user_id, = FeatureAnnouncementSubscription.decode_unsubscribe_token(params[:token])
      @user = user_id && User.find_by(id: user_id)
      head :not_found if @user.nil?
    end

    # The URL is a bearer capability, so keep it out of Referer headers, caches and indexes.
    def set_private_link_headers
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Robots-Tag"] = "noindex"
    end
end
