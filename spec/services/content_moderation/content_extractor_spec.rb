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
      expect(result.image_urls).to include(cover_preview.url(style: :original))
      expect(result.image_urls).to include("https://cdn.example.com/thumbnail.png")
      expect(result.image_urls).to include("https://cdn.example.com/description.png")
      expect(result.image_urls).to include("https://signed.example.com/file.png")
      expect(result.image_urls).to include("https://cdn.example.com/rich-content.png")
    end

    it "never generates image variants (extraction runs inside the product's save transaction)" do
      # Regression test for a production Errno::ENOENT during publish:
      # generating a variant here attaches a new blob whose upload is deferred
      # to after_commit, by which point the image-processing tempfile is gone.
      # Extraction must only ever read the ORIGINAL file URLs.
      expect_any_instance_of(AssetPreview).not_to receive(:retina_variant)
      expect_any_instance_of(Thumbnail).not_to receive(:thumbnail_variant)

      result = extractor.extract_from_product(product)

      expect(result.image_urls).to include(cover_preview.url(style: :original))
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

    context "when a product file's S3 object is missing" do
      before do
        missing_file = double(s3_key: "images/missing.png", s3_filename: "missing.png")
        valid_file = double(s3_key: "images/file.png", s3_filename: "file.png")
        allow(ProductFile).to receive(:where)
          .with(id: [123], filegroup: "image")
          .and_return([missing_file, valid_file])
        allow(extractor).to receive(:signed_download_url_for_s3_key_and_filename)
          .with("images/missing.png", "missing.png", expires_in: 1.hour)
          .and_raise(Aws::S3::Errors::NotFound.new(nil, "Key not found"))
        allow(extractor).to receive(:signed_download_url_for_s3_key_and_filename)
          .with("images/file.png", "file.png", expires_in: 1.hour)
          .and_return("https://signed.example.com/file.png")
      end

      it "skips the missing file and collects remaining valid image URLs" do
        result = extractor.extract_from_product(product)

        expect(result.image_urls).to include("https://signed.example.com/file.png")
        expect(result.image_urls).not_to include(nil)
      end
    end
  end

  describe "#extract_from_product with missing S3 objects" do
    let(:extractor) { described_class.new }
    let(:product) { create(:product, name: "Test Product", description: "<p>Description</p>") }
    let(:rich_content) do
      build(
        :product_rich_content,
        entity: product,
        description: [
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Body" }] }
        ]
      )
    end

    before do
      allow(product).to receive(:display_asset_previews).and_return(AssetPreview.none)
      allow(product).to receive(:thumbnail).and_return(double(present?: false))
      allow(product).to receive(:alive_rich_contents).and_return([rich_content])
      allow(rich_content).to receive(:embedded_product_file_ids_in_order).and_return([1, 2])

      missing_file = double(s3_key: "attachments/missing.jpg", s3_filename: "missing.jpg")
      valid_file = double(s3_key: "attachments/valid.png", s3_filename: "valid.png")
      allow(ProductFile).to receive(:where)
        .with(id: [1, 2], filegroup: "image")
        .and_return([missing_file, valid_file])
      allow(extractor).to receive(:signed_download_url_for_s3_key_and_filename)
        .with("attachments/missing.jpg", "missing.jpg", expires_in: 1.hour)
        .and_raise(Aws::S3::Errors::NotFound.new(nil, "Key not found"))
      allow(extractor).to receive(:signed_download_url_for_s3_key_and_filename)
        .with("attachments/valid.png", "valid.png", expires_in: 1.hour)
        .and_return("https://signed.example.com/valid.png")
    end

    it "skips files with missing S3 objects without raising" do
      result = extractor.extract_from_product(product)

      expect(result.image_urls).to eq(["https://signed.example.com/valid.png"])
    end
  end

  describe "#extract_from_page" do
    let(:extractor) { described_class.new }
    let(:seller) { create(:user) }

    # Built, not saved: the extractor reads the page as submitted, and saving
    # would run both the sanitizer and the moderation validation these examples
    # are the input to.
    def page_for(custom_html: nil, content: nil, title: "About my studio", pageable: seller)
      Page.new(pageable:, slug: "about", title:, custom_html:, content:)
    end

    it "extracts the title, visible text, link targets, and remote image URLs" do
      page = page_for(custom_html: <<~HTML)
        <html><head><style>.a { color: red }</style></head>
        <body>
          <h1>Hand-lettered posters</h1>
          <p>Printed to order.</p>
          <img src="https://cdn.example.com/poster.png">
          <a href="https://example.com/shop">My other shop</a>
        </body></html>
      HTML

      result = extractor.extract_from_page(page)

      expect(result.text).to include("Title: About my studio")
      expect(result.text).to include("Hand-lettered posters")
      expect(result.text).to include("Printed to order.")
      expect(result.text).to include("https://example.com/shop")
      expect(result.image_urls).to eq(["https://cdn.example.com/poster.png"])
    end

    it "ignores script, style, and template bodies so framework code is not moderated as content" do
      page = page_for(custom_html: <<~HTML)
        <style>.buy { background: red }</style>
        <script>const scriptOnlyToken = "gibberish payload";</script>
        <noscript>Enable JavaScript</noscript>
        <template><p>Cloned later</p></template>
        <p>Real copy</p>
      HTML

      result = extractor.extract_from_page(page)

      expect(result.text).to include("Real copy")
      expect(result.text).not_to include("scriptOnlyToken")
      expect(result.text).not_to include("Enable JavaScript")
      expect(result.text).not_to include("Cloned later")
    end

    it "reads rich text pages the same way as custom HTML pages" do
      page = page_for(title: "Rich", content: "<p>Written in the editor</p>")

      result = extractor.extract_from_page(page)

      expect(result.text).to include("Title: Rich")
      expect(result.text).to include("Written in the editor")
    end

    it "strips the seller's own storefront host from link targets, keeping third-party links intact" do
      page = page_for(custom_html: %(<a href="#{seller.subdomain_with_protocol}/l/thing">Mine</a><a href="https://elsewhere.example/x">Theirs</a>))

      result = extractor.extract_from_page(page)

      expect(result.text).not_to include(seller.subdomain)
      expect(result.text).to include("https://elsewhere.example/x")
    end

    it "excludes data: and relative image sources, which a classifier cannot fetch by URL" do
      page = page_for(custom_html: <<~HTML)
        <img src="data:image/png;base64,AAAA">
        <img src="/local/asset.png">
        <img src="https://cdn.example.com/remote.png">
      HTML

      expect(extractor.extract_from_page(page).image_urls).to eq(["https://cdn.example.com/remote.png"])
    end

    it "truncates the text and caps the image URLs so one page cannot make an unbounded moderation call" do
      many_images = (1..30).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
      page = page_for(custom_html: "<p>#{"word " * 8_000}</p>#{many_images}")

      result = extractor.extract_from_page(page)

      expect(result.text.length).to be <= described_class::MAX_PAGE_TEXT_LENGTH + described_class::MAX_PAGE_LINK_TEXT_LENGTH
      expect(result.text).to end_with("word")
      expect(result.image_urls.size).to eq(described_class::MAX_PAGE_IMAGE_URLS)
    end

    it "keeps link targets when the prose alone would exhaust the whole text budget" do
      padding = "word " * 8_000
      page = page_for(custom_html: %(<p>#{padding}</p><a href="https://linkfarm.example/deals">deals</a>))

      result = extractor.extract_from_page(page)

      expect(result.text).to include("https://linkfarm.example/deals")
    end

    it "picks the same images on every extraction, so re-saving cannot grind out a subset that omits one" do
      images = (1..60).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
      page = page_for(custom_html: images)

      selections = 5.times.map { extractor.extract_from_page(page).image_urls }

      expect(selections.uniq.size).to eq(1)
      expect(selections.first.size).to eq(described_class::MAX_PAGE_IMAGE_URLS)
    end

    it "does not take the images in document order, so they cannot be parked past the cap" do
      images = (1..60).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
      page = page_for(custom_html: images)

      selected = extractor.extract_from_page(page).image_urls
      document_order_prefix = (1..described_class::MAX_PAGE_IMAGE_URLS).map { |n| "https://cdn.example.com/#{n}.png" }

      expect(selected).not_to eq(document_order_prefix)
    end

    it "logs the images it could not cover when a page carries more than the cap" do
      allow(Rails.logger).to receive(:warn)
      images = (1..30).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join

      extractor.extract_from_page(page_for(custom_html: images))

      expect(Rails.logger).to have_received(:warn).with(
        /bounded page .* images to #{described_class::MAX_PAGE_IMAGE_URLS} of 30/o
      )
    end

    it "does not log when every image fits inside the cap" do
      allow(Rails.logger).to receive(:warn)

      extractor.extract_from_page(page_for(custom_html: %(<img src="https://cdn.example.com/only.png">)))

      expect(Rails.logger).not_to have_received(:warn).with(/bounded page/)
    end

    it "caps images at what the classifier will moderate, so every extracted URL gets an attempt" do
      expect(described_class::MAX_PAGE_IMAGE_URLS)
        .to eq(ContentModeration::Strategies::ClassifierStrategy::MAX_IMAGES_TO_MODERATE)
    end

    it "reads a product landing page takeover, whose owner is the product's seller" do
      page = page_for(pageable: create(:product, user: seller), custom_html: "<p>Buy my thing</p>")

      expect(extractor.extract_from_page(page).text).to include("Buy my thing")
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

    context "when the message links to the seller's own first-party storefront" do
      let(:seller) { create(:user, username: "xinnxsya") }
      let(:post) do
        build(
          :post,
          seller:,
          name: "Weekly update",
          message: %(<p>New drop here: #{seller.subdomain_with_protocol}</p>)
        )
      end

      it "strips the seller's own subdomain URL from the moderated text" do
        # Regression for antiwork/gumroad-private#727: a seller's own first-party
        # storefront URL must never be judged as policy-violating content.
        result = extractor.extract_from_post(post)

        expect(result.text).not_to include(seller.subdomain)
        expect(result.text).to include("New drop here:")
      end

      it "leaves third-party URLs intact so off-site abuse is still moderated" do
        post.message = %(<p>Mine: #{seller.subdomain_with_protocol} and theirs: https://evil.example.com/scam</p>)

        result = extractor.extract_from_post(post)

        expect(result.text).not_to include(seller.subdomain)
        expect(result.text).to include("https://evil.example.com/scam")
      end

      it "does not strip an unverified custom domain (only active ones are first-party)" do
        # Guard against a moderation bypass: an alive-but-unverified custom domain
        # is an arbitrary off-site URL the seller never proved they own, so it must
        # still be moderated. Mirrors UrlService#custom_domain_with_protocol.
        allow(seller).to receive(:custom_domain).and_return(
          double(active?: false, domain: "unverified-offsite.example.com")
        )
        post.message = %(<p>Check https://unverified-offsite.example.com/x</p>)

        result = extractor.extract_from_post(post)

        expect(result.text).to include("https://unverified-offsite.example.com/x")
      end

      it "preserves path/query text on the seller's own URL so it is still moderated" do
        # Only the gibberish domain label is the false positive; user-controlled
        # path/query text must still reach moderation so a seller can't hide a
        # blocked term inside their own URL.
        post.message = %(<p>See #{seller.subdomain_with_protocol}/forbidden-term?q=alsoflagged</p>)

        result = extractor.extract_from_post(post)

        expect(result.text).not_to include(seller.subdomain)
        expect(result.text).to include("forbidden-term")
        expect(result.text).to include("alsoflagged")
      end
    end
  end
end
