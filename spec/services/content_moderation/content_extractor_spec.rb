# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ContentExtractor do
  describe "#extract_from_product" do
    let(:extractor) { described_class.new }
    let(:product) do
      create(
        :product,
        name: "Moderated Product",
        description: '<p>Main description</p><img src="https://cdn.example.com/description.png">'
      )
    end
    let!(:cover_preview) { create(:asset_preview_jpg, link: product) }
    let(:rich_content) do
      build(
        :product_rich_content,
        entity: product,
        description: [
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Rich content body" }] },
          { "type" => "image", "attrs" => { "src" => "https://cdn.example.com/rich-content.png" } }
        ]
      )
    end

    before do
      allow(product).to receive(:thumbnail).and_return(double(present?: true, url: "https://cdn.example.com/thumbnail.png"))
      allow(product).to receive(:alive_rich_contents).and_return([rich_content])
      allow(rich_content).to receive(:embedded_product_file_ids_in_order).and_return([123])
      allow(ProductFile).to receive(:where)
        .with(id: [123], filegroup: "image")
        .and_return([double(s3_key: "images/file.png", s3_filename: "file.png")])
      allow(extractor).to receive(:signed_download_url_for_s3_key_and_filename)
        .with("images/file.png", "file.png", expires_in: 1.hour)
        .and_return("https://signed.example.com/file.png")
    end

    it "extracts product text and image URLs" do
      result = extractor.extract_from_product(product)

      expect(result.text).to include("Name: Moderated Product")
      expect(result.text).to include("Main description")
      expect(result.text).to include("Rich content body")
      expect(result.image_urls).to include(cover_preview.url)
      expect(result.image_urls).to include("https://cdn.example.com/thumbnail.png")
      expect(result.image_urls).to include("https://cdn.example.com/description.png")
      expect(result.image_urls).to include("https://signed.example.com/file.png")
      expect(result.image_urls).to include("https://cdn.example.com/rich-content.png")
    end

    it "handles nil URLs from cover image previews without raising" do
      allow(product.display_asset_previews).to receive(:joins).and_return(
        double(where: double(map: [nil, "https://cdn.example.com/valid.png", ""]))
      )

      result = extractor.extract_from_product(product)

      expect(result.image_urls).to include("https://cdn.example.com/valid.png")
      expect(result.image_urls).not_to include(nil)
      expect(result.image_urls).not_to include("")
    end
  end

  describe "#extract_from_post" do
    let(:extractor) { described_class.new }
    let(:post) do
      build(
        :post,
        name: "Moderated Post",
        message: '<div><p>Hello <strong>world</strong></p><img src="https://cdn.example.com/post.png"></div>'
      )
    end

    it "parses the post HTML once and extracts text and images" do
      expect(Nokogiri).to receive(:HTML).once.and_call_original

      result = extractor.extract_from_post(post)

      expect(result.text).to eq("Name: Moderated Post Message: Hello world")
      expect(result.image_urls).to eq(["https://cdn.example.com/post.png"])
    end

    it "ignores images without a src attribute" do
      post.message = '<div><p>Hello</p><img><img src="https://cdn.example.com/post.png"></div>'

      result = extractor.extract_from_post(post)

      expect(result.image_urls).to eq(["https://cdn.example.com/post.png"])
    end

    it "ignores images with an empty src attribute" do
      post.message = '<div><p>Hello</p><img src=""><img src="https://cdn.example.com/post.png"></div>'

      result = extractor.extract_from_post(post)

      expect(result.image_urls).to eq(["https://cdn.example.com/post.png"])
    end
  end
end
