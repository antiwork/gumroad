# frozen_string_literal: true

module Product::StructuredData
  extend ActiveSupport::Concern
  include ActionView::Helpers::SanitizeHelper

  def structured_data
    return {} unless native_type == Link::NATIVE_TYPE_EBOOK

    data = {
      "@context" => "https://schema.org",
      "@type" => "Book",
      "name" => name,
      "author" => {
        "@type" => "Person",
        "name" => user.name
      },
      "description" => product_description,
      "url" => long_url
    }

    work_examples = build_book_work_examples
    data["workExample"] = work_examples if work_examples.any?
    data
  end

  private
    def build_book_work_examples
      book_files = alive_product_files.select(&:supports_isbn?)

      book_files.map do |file|
        work_example = {
          "@type" => "Book",
          "bookFormat" => "EBook",
          "name" => "#{name} (#{file.filetype.upcase})"
        }

        work_example["isbn"] = file.isbn if file.isbn.present?
        work_example
      end
    end

    def product_description
      (custom_summary.presence || strip_tags(html_safe_description).presence)
        .to_s
        .truncate(160)
        .presence
    end
end
