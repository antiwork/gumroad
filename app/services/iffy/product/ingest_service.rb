# frozen_string_literal: true

class Iffy::Product::IngestService
  include SignedUrlHelper
  include Rails.application.routes.url_helpers

  URL = Rails.env.production? ? "https://api.iffy.com/api/v1/ingest" : "http://localhost:3000/api/v1/ingest"

  def initialize(product)
    @product = product
  end

  def perform
    iffy_api_request
  end

  private
    attr_reader :product

    PERMITTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    def iffy_api_request
      user_data = {
        clientId: product.user.external_id,
        protected: product.user.vip_creator?
      }
      user_data[:email] = product.user.email if product.user.email.present?
      user_data[:username] = product.user.username if product.user.username.present?
      user_data[:stripeAccountId] = product.user.stripe_account&.charge_processor_merchant_id if product.user.stripe_account&.charge_processor_merchant_id.present?

      response = HTTParty.post(
        URL,
        {
          body: {
            clientId: product.external_id,
            clientUrl: product.long_url,
            name: product.name,
            entity: "Product",
            text:,
            fileUrls: image_urls,
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
        error_message = "Iffy error for product ID #{product.id}: #{response.code} - #{message}"
        raise error_message
      end
    end

    def text
      "Name: #{product.name} Description: #{product.description} " + text_content(rich_contents)
    end

    def image_urls
      cover_image_urls = product.display_asset_previews.joins(file_attachment: :blob)
                                .where(active_storage_blobs: { content_type: PERMITTED_IMAGE_TYPES })
                                .map(&:url)

      thumbnail_image_urls = product.thumbnail.present? ? [product.thumbnail.url] : []

      product_description_image_urls = Nokogiri::HTML(product.link.description).css("img").filter_map { |img| img["src"] }

      rich_content_file_image_urls = rich_contents.flat_map do |rich_content|
        ProductFile.where(id: rich_content.embedded_product_file_ids_in_order, filegroup: "image").map do
          # the only way to generate a permanent Cloudfront signed url is to set a long expiry time
          # see https://stackoverflow.com/a/55729193
          signed_download_url_for_s3_key_and_filename(_1.s3_key, _1.s3_filename, expires_in: 99.years)
        end
      end

      rich_content_embedded_image_urls = rich_contents.flat_map do |rich_content|
        rich_content.description.filter_map do |node|
          node.dig("attrs", "src") if node["type"] == "image"
        end
      end.compact

      (cover_image_urls +
        thumbnail_image_urls +
        product_description_image_urls +
        rich_content_file_image_urls +
        rich_content_embedded_image_urls
      ).reject(&:empty?)
    end

    def text_content(rich_contents)
      rich_contents.flat_map do |rich_content|
        extract_text(rich_content.description)
      end.join(" ")
    end

    def extract_text(content)
      case content
      when Array
        content.flat_map { |item| extract_text(item) }
      when Hash
        if content["text"]
          Array.wrap(content["text"])
        else
          content.values.flat_map { |value| extract_text(value) }
        end
      else
        []
      end
    end

    def rich_contents
      product.alive_rich_contents
    end
end
