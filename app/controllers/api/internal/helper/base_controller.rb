# frozen_string_literal: true

class Api::Internal::Helper::BaseController < Api::Internal::BaseController
  skip_before_action :verify_authenticity_token
  before_action :verify_authorization_header!
  before_action :authorize_helper_token!

  HMAC_EXPIRATION = 1.minute

  private
    def authorize_hmac_signature!
      json = request.body.read.empty? ? nil : JSON.parse(request.body.read)
      query_params = json ? nil : request.query_parameters
      timestamp = json ? json.dig("timestamp") : query_params[:timestamp]

      return render json: { success: false, message: "timestamp is required" }, status: :bad_request if timestamp.blank?

      if (Time.at(timestamp.to_i) - Time.now).abs > HMAC_EXPIRATION
        return render json: { success: false, message: "bad timestamp" }, status: :unauthorized
      end

      hmac_digest = Base64.decode64(request.authorization.split(" ").last)
      expected_digest = Helper::Client.new.create_hmac_digest(params: query_params, json:)
      unless ActiveSupport::SecurityUtils.secure_compare(hmac_digest, expected_digest)
        render json: { success: false, message: "authorization is invalid" }, status: :unauthorized
      end
    end

    def authorize_helper_token!
      token = request.authorization.split(" ").last
      unless ActiveSupport::SecurityUtils.secure_compare(token, GlobalConfig.get("HELPER_TOOLS_TOKEN"))
        render json: { success: false, message: "authorization is invalid" }, status: :unauthorized
      end
    end

    def verify_authorization_header!
      render json: { success: false, message: "unauthenticated" }, status: :unauthorized if request.authorization.nil?
    end
end
