# frozen_string_literal: true

class Internal::BaseController < ApplicationController
  def authorize_request
    return render json: { success: false }, status: :unauthorized if request.authorization.nil?

    decoded_credentials = ::Base64.decode64(request.authorization.split(" ", 2).last || "").split(":")
    username = decoded_credentials[0]
    password = decoded_credentials[1]

    render json: { success: false }, status: :unauthorized if username != SPEC_API_USERNAME || password != SPEC_API_PASSWORD
  end
end
