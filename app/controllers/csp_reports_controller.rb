# frozen_string_literal: true

class CspReportsController < ApplicationController
  # Skip CSRF protection for CSP violation reports
  skip_before_action :verify_authenticity_token

  # Skip authentication for CSP reports
  skip_before_action :authenticate_user!, if: -> { action_name == "create" }

  def create
    # Log CSP violation reports for monitoring
    Rails.logger.warn("CSP Violation: #{csp_report_params.to_json}")

    # Optionally store in database for analysis (uncomment if needed)
    # CspViolation.create(
    #   document_uri: csp_report_params[:document_uri],
    #   violated_directive: csp_report_params[:violated_directive],
    #   blocked_uri: csp_report_params[:blocked_uri],
    #   source_file: csp_report_params[:source_file],
    #   line_number: csp_report_params[:line_number],
    #   user_agent: request.user_agent,
    #   ip_address: request.remote_ip
    # )

    head :no_content
  end

  private
    def csp_report_params
      # CSP reports come nested under 'csp-report' key
      if params["csp-report"].present?
        params.require("csp-report").permit(
          :document_uri,
          :referrer,
          :violated_directive,
          :effective_directive,
          :original_policy,
          :blocked_uri,
          :status_code,
          :source_file,
          :line_number,
          :column_number
        )
      else
        # Fallback for direct parameters
        params.permit(
          :document_uri,
          :referrer,
          :violated_directive,
          :effective_directive,
          :original_policy,
          :blocked_uri,
          :status_code,
          :source_file,
          :line_number,
          :column_number
        )
      end
    end
end
