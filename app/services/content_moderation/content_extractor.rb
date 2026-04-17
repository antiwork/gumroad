# frozen_string_literal: true

class ContentModeration::ContentExtractor
  include SignedUrlHelper
  include Rails.application.routes.url_helpers

  PERMITTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]

  Result = Struct.new(:text, :image_urls, keyword_init: true)

  def extract_from_product(product, text_only: false)
    text = "Name: #{product.name} Description: #{product.description} " + rich_content_text(product.alive_rich_contents)
    image_urls = text_only ? [] : product_image_urls(product)
    Result.new(text: text, image_urls: image_urls)
  end

  def extract_from_post(installment, text_only: false)
    parsed_message = Nokogiri::HTML(installment.message)
    text = "Name: #{installment.name} Message: #{parsed_message.text}"
    image_urls = text_only ? [] : parsed_message.css("img").filter_map { |img| img["src"] }.reject(&:empty?)
    Result.new(text: text, image_urls: image_urls)
  end

  def extract_from_profile(user, text_only: false)
    rich_text_sections = SellerProfileRichTextSection.where(seller_id: user.id)

    text = "#{user.display_name} #{user.bio} #{profile_rich_text_content(rich_text_sections)}"

    image_urls = if text_only
                   []
                 else
                   rich_text_sections.flat_map do |section|
                     section.json_data.dig("text", "content")&.filter_map do |content|
                       content.dig("attrs", "src") if content["type"] == "image"
                     end
                   end.compact.reject(&:empty?)
                 end

    Result.new(text: text, image_urls: image_urls)
  end

  private
    def product_image_urls(product)
      cover_image_urls = product.display_asset_previews.joins(file_attachment: :blob)
                                .where(active_storage_blobs: { content_type: PERMITTED_IMAGE_TYPES })
                                .map(&:url)

      thumbnail_image_urls = product.thumbnail.present? ? [product.thumbnail.url] : []

      product_description_image_urls = Nokogiri::HTML(product.link.description).css("img").filter_map { |img| img["src"] }

      rich_contents = product.alive_rich_contents

      rich_content_file_image_urls = rich_contents.flat_map do |rich_content|
        ProductFile.where(id: rich_content.embedded_product_file_ids_in_order, filegroup: "image").map do
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

    def rich_content_text(rich_contents)
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

    def profile_rich_text_content(rich_text_sections)
      rich_text_sections.map do |section|
        section.json_data.dig("text", "content")&.filter_map do |content|
          if content["type"] == "paragraph" && content["content"]
            content["content"].map { |item| item["text"] }.join
          end
        end
      end.flatten.join(" ")
    end
end
