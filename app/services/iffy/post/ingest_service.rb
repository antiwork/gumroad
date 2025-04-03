# frozen_string_literal: true

class Iffy::Post::IngestService
  URL = Rails.env.production? ? "https://api.iffy.com/api/v1/ingest" : "http://localhost:3000/api/v1/ingest"

  def initialize(installment)
    @installment = installment
  end

  def perform
    iffy_api_request
  end

  private
    attr_reader :installment

    PERMITTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    def iffy_api_request
      user_data = {
        clientId: installment.user.external_id,
        protected: installment.user.vip_creator?
      }
      user_data[:email] = installment.user.email if installment.user.email.present?
      user_data[:username] = installment.user.username if installment.user.username.present?
      user_data[:stripeAccountId] = installment.user.stripe_account&.charge_processor_merchant_id if installment.user.stripe_account&.charge_processor_merchant_id.present?

      response = HTTParty.post(
        URL,
        {
          body: {
            clientId: installment.external_id,
            clientUrl: installment.full_url,
            name: installment.name,
            entity: "Post",
            text: text,
            fileUrls: file_urls,
            user: user_data
          }.to_json,
          headers: {
            "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
          }
        }
      )

      if response.success?
        response.parsed_response
      else
        message = if response.parsed_response.is_a?(Hash)
          response.parsed_response.dig("error", "message")
        elsif response.parsed_response.is_a?(String)
          response.parsed_response
        else
          response.body
        end
        error_message = "Iffy error for installment ID #{installment.id}: #{response.code} - #{message}"
        raise error_message
      end
    end

    def text
      "Name: #{installment.name} Message: #{extract_text_from_message}"
    end

    def extract_text_from_message
      Nokogiri::HTML(installment.message).text
    end

    def file_urls
      doc = Nokogiri::HTML(installment.message)
      doc.css("img").map { |img| img["src"] }.reject(&:empty?)
    end
end
