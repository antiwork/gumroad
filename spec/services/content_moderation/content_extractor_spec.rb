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

    it "counts only the images that survive sanitization, while still reading text the sanitizer drops" do
      page = page_for(custom_html: <<~HTML)
        <img src="https://cdn.example.com/kept.png">
        <marquee>buy illegal things<img src="https://cdn.example.com/dropped.png"></marquee>
      HTML

      result = extractor.extract_from_page(page)

      # An image inside a dropped tag never renders, so counting it would reject a
      # page over a limit it does not really reach. Text in one still says
      # something, so it is still moderated.
      expect(result.image_urls).to eq(["https://cdn.example.com/kept.png"])
      expect(result.text).to include("buy illegal things")
    end

    it "extracts every image the page can display, not just img src" do
      page = page_for(custom_html: <<~HTML)
        <img src="https://cdn.example.com/remote.png">
        <img srcset="https://cdn.example.com/one.png 1x, https://cdn.example.com/two.png 2x">
        <picture><source srcset="https://cdn.example.com/source.png"></picture>
        <video poster="https://cdn.example.com/poster.jpg"></video>
      HTML

      # The sanitizer permits srcset and poster, so an image reachable only
      # through one of them renders to every visitor.
      expect(extractor.extract_from_page(page).image_urls).to match_array([
                                                                            "https://cdn.example.com/remote.png",
                                                                            "https://cdn.example.com/one.png",
                                                                            "https://cdn.example.com/two.png",
                                                                            "https://cdn.example.com/source.png",
                                                                            "https://cdn.example.com/poster.jpg",
                                                                          ])
    end

    it "extracts images whose scheme is not lowercase, which browsers render all the same" do
      page = page_for(custom_html: <<~HTML)
        <img src="HTTPS://cdn.example.com/upper.png">
        <img srcset="Http://cdn.example.com/mixed.png 1x">
        <video poster="HTTPS://cdn.example.com/poster.jpg"></video>
        <a href="HTTPS://elsewhere.example/shop">Shop</a>
      HTML

      result = extractor.extract_from_page(page)
      # URI schemes are case-insensitive, so a case-sensitive predicate would let
      # a seller display an image the moderation pass never sees.
      expect(result.image_urls).to match_array([
                                                 "HTTPS://cdn.example.com/upper.png",
                                                 "Http://cdn.example.com/mixed.png",
                                                 "HTTPS://cdn.example.com/poster.jpg",
                                               ])
      expect(result.text).to include("HTTPS://elsewhere.example/shop")
    end

    it "extracts inline data: images, which render without ever being uploaded" do
      page = page_for(custom_html: <<~HTML)
        <img src="data:image/png;base64,AAAA">
        <img srcset="data:image/png;base64,BBBB 1x, https://cdn.example.com/remote.png 2x">
      HTML

      # A data: URL contains commas, so srcset splitting must not bisect one.
      expect(extractor.extract_from_page(page).image_urls).to match_array([
                                                                            "data:image/png;base64,AAAA",
                                                                            "data:image/png;base64,BBBB",
                                                                            "https://cdn.example.com/remote.png",
                                                                          ])
    end

    it "re-encodes a percent-encoded raster data URL into the base64 form the classifier can review" do
      page = page_for(custom_html: <<~HTML)
        <style>.tile { background-image: url("data:image/png,%89PNG%0D%0A") }</style>
      HTML

      # The moderations endpoint only accepts base64 data URLs; sending the
      # percent-encoded form is a guaranteed 400 that blocks the page forever.
      # Same bytes, reviewable encoding.
      expect(extractor.extract_from_page(page).image_urls).to eq([
                                                                   "data:image/png;base64,#{Base64.strict_encode64("\x89PNG\r\n".b)}",
                                                                 ])
    end

    it "reviews a self-contained SVG data URL as markup text instead of blocking the page on it" do
      # The feTurbulence film-grain trick (gumroad-private#1695): the standard
      # way generated pages paint noise textures. No moderation endpoint reads
      # SVG in any encoding, but this one provably references no other image,
      # so its markup is reviewed through the text strategies instead.
      grain = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E" \
              "%3Cfilter id='grainy'%3E%3CfeTurbulence baseFrequency='0.9'/%3E%3C/filter%3E" \
              "%3Crect width='100' height='100' filter='url(%23grainy)'/%3E%3C/svg%3E"
      page = page_for(custom_html: <<~HTML)
        <style>.grain::before { background-image: url("#{grain}") }</style>
      HTML

      result = extractor.extract_from_page(page)

      expect(result.image_urls).to be_empty
      expect(result.text).to include("feTurbulence")
    end

    it "reviews a base64 SVG data URL's text the same way, including words rendered by <text>" do
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"><text>buy illegal things</text></svg>)
      page = page_for(custom_html: <<~HTML)
        <img src="data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}">
      HTML

      result = extractor.extract_from_page(page)

      expect(result.image_urls).to be_empty
      expect(result.text).to include("buy illegal things")
    end

    it "keeps an SVG that embeds another image on the image list, where full coverage blocks it" do
      # An SVG-as-image renders embedded data: payloads, so excluding this one
      # would display a raster no strategy ever reviewed.
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,AAAA"/></svg>)
      url = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
      page = page_for(custom_html: %(<img src="#{url}">))

      result = extractor.extract_from_page(page)

      expect(result.image_urls).to eq([url])
      expect(result.text).not_to include("AAAA")
    end

    it "keeps an SVG whose foreignObject could render arbitrary HTML" do
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div>anything</div></foreignObject></svg>)
      url = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
      page = page_for(custom_html: %(<img src="#{url}">))

      expect(extractor.extract_from_page(page).image_urls).to eq([url])
    end

    it "keeps an SVG that references anything outside itself" do
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"><use href="https://elsewhere.example/sprite.svg#icon"/></svg>)
      url = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
      page = page_for(custom_html: %(<img src="#{url}">))

      expect(extractor.extract_from_page(page).image_urls).to eq([url])
    end

    it "keeps an SVG whose CSS hides a nested payload behind an escape" do
      # `\\64 ata:` tokenizes to `data:` — the same escape reading css_image_urls
      # does for the page's own CSS applies inside a candidate SVG.
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"><rect style="mask-image:url(\\64 ata:image/png;base64,AAAA)"/></svg>)
      url = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
      page = page_for(custom_html: %(<img src="#{url}">))

      expect(extractor.extract_from_page(page).image_urls).to eq([url])
    end

    it "keeps an SVG that hides a nested payload behind an XML entity" do
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"><set attributeName="href" to="&#100;ata:image/png;base64,AAAA"/></svg>)
      url = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
      page = page_for(custom_html: %(<img src="#{url}">))

      expect(extractor.extract_from_page(page).image_urls).to eq([url])
    end

    it "keeps a data URL whose payload is not the SVG it claims to be" do
      url = "data:image/svg+xml;base64,#{Base64.strict_encode64("<html><p>not svg</p></html>")}"
      page = page_for(custom_html: %(<img src="#{url}">))

      expect(extractor.extract_from_page(page).image_urls).to eq([url])
    end

    it "extracts images painted by CSS, which render without any img tag" do
      page = page_for(custom_html: <<~HTML)
        <div style="background-image: url('https://cdn.example.com/inline.png')">Studio</div>
        <style>
          .hero { background: url(data:image/png;base64,AAAA) no-repeat }
          @media screen { .promo { border-image: url("https://cdn.example.com/media.png") } }
        </style>
      HTML

      # The sanitizer keeps the style attribute and tag, and the page CSP's
      # style-src 'unsafe-inline' lets them apply, so a CSS background is as
      # rendered as an img src.
      expect(extractor.extract_from_page(page).image_urls).to match_array([
                                                                            "https://cdn.example.com/inline.png",
                                                                            "data:image/png;base64,AAAA",
                                                                            "https://cdn.example.com/media.png",
                                                                          ])
    end

    it "reads CSS as a browser tokenizes it, so escapes and custom properties cannot hide an image" do
      page = page_for(custom_html: <<~HTML)
        <style>
          .a { background-image: /* comment */ url(\\68ttps://cdn.example.com/escaped.png) }
          .b { --bg: url("https://cdn.example.com/var.png") }
          .c { background-image: var(--bg) }
          .d { background-image: image-set(url("https://cdn.example.com/set.png") 1x) }
        </style>
      HTML

      expect(extractor.extract_from_page(page).image_urls).to match_array([
                                                                            "https://cdn.example.com/escaped.png",
                                                                            "https://cdn.example.com/var.png",
                                                                            "https://cdn.example.com/set.png",
                                                                          ])
    end

    it "recovers images painted through CSS nesting, which the parser cannot structure but browsers render" do
      page = page_for(custom_html: <<~HTML)
        <style>
          .card {
            --seller-image: url("https://cdn.example.com/nested-var.png");
            & .hero { background-image: var(--seller-image) }
            & .side { .deep { background-image: url("https://cdn.example.com/deep.png") } }
          }
          @media screen {
            .promo { & .banner { background: url("https://cdn.example.com/media-nested.png") } }
          }
        </style>
      HTML

      # Crass returns a nested rule as a bare :error node with its declarations
      # discarded, so without the flattened re-read these images rendered while
      # extraction had nothing to hand to moderation.
      expect(extractor.extract_from_page(page).image_urls).to match_array([
                                                                            "https://cdn.example.com/nested-var.png",
                                                                            "https://cdn.example.com/deep.png",
                                                                            "https://cdn.example.com/media-nested.png",
                                                                          ])
    end

    it "leaves unused custom-property URLs out, so a URL nothing renders cannot block a page" do
      page = page_for(custom_html: <<~HTML)
        <style>
          :root { --unused: url("https://dead.example.com/never-rendered.png") }
          .a { --indirect: url("https://cdn.example.com/chained.png") }
          .b { --painted: var(--indirect) }
        </style>
        <div style="background-image: var(--painted, var(--fallback))"></div>
        <style>
          .c { --fallback: url("https://cdn.example.com/fallback.png") }
          .d { color: var(--unused-by-a-non-image-property) }
          .e { --unused-by-a-non-image-property: url("https://dead.example.com/text-only.png") }
        </style>
      HTML

      # A custom property no image-painting declaration reads (directly, through
      # another custom property, or as a var() fallback) makes no browser
      # request — collecting it would let an unreviewable parked URL block an
      # otherwise safe page. References resolve across style attributes and
      # blocks, since custom properties inherit document-wide.
      expect(extractor.extract_from_page(page).image_urls).to match_array([
                                                                            "https://cdn.example.com/chained.png",
                                                                            "https://cdn.example.com/fallback.png",
                                                                          ])
    end

    it "leaves font URLs out of the image set, so a custom font cannot block a page" do
      page = page_for(custom_html: <<~HTML)
        <style>
          @font-face { font-family: brand; src: url("https://fonts.gstatic.com/f.woff2") }
          h1 { font-family: brand; background: url("https://cdn.example.com/hero.png") }
        </style>
      HTML

      # A font sent to the image endpoint fails moderation, and under full
      # coverage an unmoderated "image" rejects the whole page. The background
      # alongside it pins that fonts are excluded by choice, not by the
      # stylesheet going unread.
      expect(extractor.extract_from_page(page).image_urls).to eq(["https://cdn.example.com/hero.png"])
    end

    it "excludes relative image sources, which have no absolute form to send" do
      page = page_for(custom_html: %(<img src="/local/asset.png"><img src="https://cdn.example.com/remote.png">))

      expect(extractor.extract_from_page(page).image_urls).to eq(["https://cdn.example.com/remote.png"])
    end

    it "truncates the text so one page cannot make an unbounded moderation call" do
      page = page_for(custom_html: "<p>#{"word " * 8_000}</p>")

      result = extractor.extract_from_page(page)

      expect(result.text.length).to be <= described_class::MAX_PAGE_TEXT_LENGTH + described_class::MAX_PAGE_LINK_TEXT_LENGTH
      expect(result.text).to end_with("word")
    end

    it "returns every remote image, so the caller can reject a page it cannot fully review" do
      many_images = (1..30).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
      page = page_for(custom_html: many_images)

      expect(extractor.extract_from_page(page).image_urls.size).to eq(30)
    end

    it "keeps link targets when the prose alone would exhaust the whole text budget" do
      padding = "word " * 8_000
      page = page_for(custom_html: %(<p>#{padding}</p><a href="https://linkfarm.example/deals">deals</a>))

      result = extractor.extract_from_page(page)

      expect(result.text).to include("https://linkfarm.example/deals")
    end

    it "orders the images the same way on every extraction, so re-saving cannot change which are moderated first" do
      images = (1..60).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
      page = page_for(custom_html: images)

      selections = 5.times.map { extractor.extract_from_page(page).image_urls }

      expect(selections.uniq.size).to eq(1)
      expect(selections.first.size).to eq(60)
    end

    it "does not return the images in document order, so a prefix-shaped cap could not be gamed" do
      images = (1..60).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
      page = page_for(custom_html: images)

      document_order = (1..60).map { |n| "https://cdn.example.com/#{n}.png" }

      expect(extractor.extract_from_page(page).image_urls).not_to eq(document_order)
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
