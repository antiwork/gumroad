# frozen_string_literal: true

class TiktokCallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:deauthorize]

  def deauthorize
    payload = webhook.parse(request.raw_post, signature_header)
    return head :bad_request if payload.blank?
    return head :ok unless payload["event"] == "authorization.removed"

    open_id = webhook.open_id(payload)
    return head :bad_request if open_id.blank?

    unlink_tiktok_identity(open_id)
    head :ok
  end

  private
    def webhook
      @_webhook ||= TiktokWebhook.new
    end

    def signature_header
      request.get_header("HTTP_TIKTOK_SIGNATURE") || request.headers["TikTok-Signature"] || request.headers["Tiktok-Signature"]
    end

    # Deauthorize only ends the live link; the verified identity stays as
    # shared-identity veto evidence, like an in-app disconnect.
    def unlink_tiktok_identity(open_id)
      SocialConnectVerification.current.where(platform: "tiktok", uid: open_id).update_all(superseded_at: Time.current)
      UserTiktokIdentity.where(tiktok_open_id: open_id).delete_all
    end
end
