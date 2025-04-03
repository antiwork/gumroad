# frozen_string_literal: true

class RichContentImagesRetrievalService
  attr_reader :content, :is_json

  def initialize(content:, is_json:)
    @content = content
    @is_json = is_json
  end

  # Returns an array of found image URLs
  def parse
    is_json ? parse_json(content) : parse_html
  end

  private
    def parse_json(content)
      content.map do |node|
        if node["type"] == "image"
          node.dig("attrs", "src")
        elsif node["content"]
          parse_json(node["content"])
        end
      end.flatten.compact
    end

    def parse_html
      Nokogiri::HTML(content).css("img").map { |img| img["src"] }.compact
    end
end
