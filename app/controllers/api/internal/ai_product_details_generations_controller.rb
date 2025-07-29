# frozen_string_literal: true

class Api::Internal::AiProductDetailsGenerationsController < Api::Internal::BaseController
  include Throttling

  before_action :authenticate_user!
  before_action :throttle_ai_requests
  after_action :verify_authorized

  AI_REQUESTS_PER_PERIOD = 10
  AI_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AI_REQUESTS_PER_PERIOD, :AI_REQUESTS_PERIOD_WINDOW

  def create
    authorize current_seller, :generate_product_details_with_ai?

    prompt = params[:prompt]

    if prompt.blank?
      render json: { error: "Prompt is required" }, status: :bad_request
      return
    end

    begin
      service = ::Ai::ProductDetailsGeneratorService.new(current_seller: current_seller)
      result = service.generate_product_details(prompt: sanitize_prompt(prompt))

      render json: {
        success: true,
        data: {
          name: result[:name],
          description: result[:description],
          summary: result[:summary],
          number_of_content_pages: result[:number_of_content_pages],
          price: result[:price],
          currency_code: result[:currency_code],
          price_frequency_in_months: result[:price_frequency_in_months],
          native_type: result[:native_type],
          duration_in_seconds: result[:duration_in_seconds]
        }
      }
    rescue => e
      Rails.logger.error "Product details generation using AI failed: #{e.full_message}"
      Bugsnag.notify(e)
      render json: {
        success: false,
        error: "Failed to generate product details. Please try again."
      }, status: :internal_server_error
    end
  end

  private
    def throttle_ai_requests
      return unless current_user

      key = RedisKey.ai_request_throttle(current_seller.id)
      throttle!(key:, limit: AI_REQUESTS_PER_PERIOD, period: AI_REQUESTS_PERIOD_WINDOW)
    end

    def sanitize_prompt(prompt)
      sanitized = prompt.gsub(/\b(ignore|forget|system|assistant|user|delete|remove|clear|impersonate)\s+(previous|above|all)\b/i, "[FILTERED]")
      sanitized.gsub(/[^\w\s.,!?\-\[\]]/, "").strip
    end
end
