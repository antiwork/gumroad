# frozen_string_literal: true

class Api::Internal::Helper::IffyAppealsController < Api::Internal::Helper::BaseController
  before_action :authorize_helper_token!

  CREATE_APPEAL_OPENAPI = {
    summary: "Create Iffy appeal",
    description: "Create an appeal for a suspended user who believes they have been suspended in error",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the user" },
              reason: { type: "string", description: "Reason for the appeal" }
            },
            required: ["email", "reason"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully created appeal",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                id: { type: "string", description: "ID of the appeal" },
                appeal_url: { type: "string", description: "URL for the user to view their appeal"  }
              }
            }
          }
        }
      },
      '422': {
        description: "Invalid parameters or appeal creation failed",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                error_message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def create
    if params[:email].blank? || params[:reason].blank?
      return render json: { success: false, error_message: "Email and reason are required" }, status: :unprocessable_entity
    end

    user = User.alive.by_email(params[:email]).first
    if user.blank?
      return render json: { success: false, error_message: "An account does not exist with that email." }, status: :unprocessable_entity
    end

    iffy_url = Rails.env.production? ? "https://api.iffy.com/api/v1" : "http://localhost:3000/api/v1"

    begin
      response = HTTParty.get(
        "#{iffy_url}/users?email=#{CGI.escape(params[:email])}",
        headers: {
          "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
        }
      )

      if !(response.success? && response.parsed_response["data"].present? && !response.parsed_response["data"].empty?)
        return render json: { success: false, error_message: "Failed to retrieve user" }, status: :service_unavailable
      end

      user_data = response.parsed_response["data"].first
      user_id = user_data["id"]

      response = HTTParty.post(
        "#{iffy_url}/users/#{user_id}/create_appeal",
        headers: {
          "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
        },
        body: {
          text: params[:reason]
        }
      )

      if !(response.success? && response.parsed_response["data"].present? && !response.parsed_response["data"].empty?)
        return render json: { success: false, error_message: "Failed to create appeal" }, status: :service_unavailable
      end

      appeal_data = response.parsed_response["data"].first
      appeal_id = appeal_data["id"]
      appeal_url = appeal_data["url"]

      render json: {
        success: true,
        id: appeal_id,
        appeal_url: appeal_url
      }
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
      Bugsnag.notify(e)

      render json: {
        success: false,
        error_message: "Failed to create appeal"
      }, status: :service_unavailable
    end
  end
end
