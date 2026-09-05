# frozen_string_literal: true

class InstagramCallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:deauthorize, :data_deletion]

  def deauthorize
    user_id = signed_request_user_id
    return head :bad_request if user_id.blank?

    delete_instagram_data(user_id)
    head :ok
  end

  def data_deletion
    user_id = signed_request_user_id
    return head :bad_request if user_id.blank?

    delete_instagram_data(user_id)
    confirmation_code = signed_request.confirmation_code(user_id)
    render json: {
      url: instagram_data_deletion_status_url(confirmation_code:),
      confirmation_code:,
    }
  end

  def data_deletion_status
    return head :not_found unless signed_request.valid_confirmation_code?(params[:confirmation_code])

    render plain: "Instagram data deletion completed."
  end

  private
    def signed_request_user_id
      signed_request.parse(params[:signed_request])&.fetch("user_id", nil)&.to_s
    end

    def signed_request
      @_signed_request ||= InstagramSignedRequest.new
    end

    def delete_instagram_data(user_id)
      SocialConnectVerification.where(platform: "instagram", uid: user_id).delete_all
    end
end
