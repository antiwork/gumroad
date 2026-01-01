# frozen_string_literal: true

class Iffy::Profile::IngestService
  include Rails.application.routes.url_helpers

  URL = Rails.env.production? ? "https://api.iffy.com/api/v1/ingest" : "http://localhost:3000/api/v1/ingest"
  TEST_MODE = Rails.env.test?

  def initialize(user)
    @user = user
  end

  def perform
    return if TEST_MODE
    iffy_api_request
  end

  private
    attr_reader :user

    def iffy_api_request
      user_data = {
        clientId: user.external_id,
        protected: user.vip_creator?
      }
      user_data[:email] = user.email if user.email.present?
      user_data[:username] = user.username if user.username.present?
      user_data[:stripeAccountId] = user.stripe_account&.charge_processor_merchant_id if user.stripe_account&.charge_processor_merchant_id.present?

      response = HTTParty.post(
        URL,
        {
          body: {
            clientId: user.external_id,
            clientUrl: user.profile_url,
            name: user.display_name,
            entity: "Profile",
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
        error_message = "Iffy error for user ID #{user.id}: #{response.code} - #{message}"
        raise error_message
      end
    end

    def text
      "#{user.display_name} #{user.bio} #{rich_text_content}"
    end

    def file_urls
      rich_text_sections.flat_map do |section|
        section.json_data.dig("text", "content")&.filter_map do |content|
          content.dig("attrs", "src") if content["type"] == "image"
        end
      end.compact.reject(&:empty?)
    end

    def rich_text_content
      rich_text_sections.map do |section|
        section.json_data.dig("text", "content")&.filter_map do |content|
          if content["type"] == "paragraph" && content["content"]
            content["content"].map { |item| item["text"] }.join
          end
        end
      end.flatten.join(" ")
    end

    def rich_text_sections
      @rich_text_sections ||= SellerProfileRichTextSection.where(seller_id: user.id)
    end
end
