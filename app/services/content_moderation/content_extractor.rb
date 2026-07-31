# frozen_string_literal: true

class ContentModeration::ContentExtractor
  include SignedUrlHelper
  include Rails.application.routes.url_helpers

  PERMITTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]

  # Storefront pages carry up to Page::MAX_CUSTOM_HTML_LENGTH (500k) characters
  # of seller-authored HTML, an order of magnitude more prose than a product
  # listing. The visible text is what the moderation strategies read, so it is
  # truncated to keep one page save from becoming a very large, very slow model
  # call. Abuse worth catching (keyword farms, adult copy, off-platform pitches)
  # is never confined to the tail of a document — it is the page's subject.
  MAX_PAGE_TEXT_LENGTH = 20_000

  # Also bounded, for the same reason: a generated page can reference hundreds
  # of images, while ClassifierStrategy moderates the first few
  # (MAX_IMAGES_TO_MODERATE) and PromptStrategy sends what it is given.
  MAX_PAGE_IMAGE_URLS = 20

  Result = Struct.new(:text, :image_urls, keyword_init: true)

  def extract_from_product(product)
    description_text = Nokogiri::HTML(product.description.to_s).text
    text = "Name: #{product.name} Description: #{description_text} " + rich_content_text(product.alive_rich_contents)
    text = strip_seller_first_party_urls(text, product.user)
    Result.new(text: text, image_urls: product_image_urls(product))
  end

  def extract_from_post(installment)
    parsed_message = Nokogiri::HTML(installment.message)
    text = "Name: #{installment.name} Message: #{parsed_message.text}"
    text = strip_seller_first_party_urls(text, installment.user)
    image_urls = parsed_message.css("img").filter_map { |img| img["src"] }.reject(&:empty?)
    Result.new(text: text, image_urls: image_urls)
  end

  # A storefront page: either the profile/product custom HTML takeover or a
  # slugged page, carrying rich text `content` or a full `custom_html` document.
  #
  # Both representations are read the same way — as a document whose visible
  # text and images are what a visitor sees. Link targets are included in the
  # text because a page is a publishing surface: the abuse that shows up here is
  # usually a set of outbound links (an SEO farm, a redirect to an off-platform
  # storefront) rather than the prose around them.
  def extract_from_page(page)
    document = Nokogiri::HTML(page.custom_html.presence || page.content.to_s)

    # Script and style bodies are code, not content, and a page built on a CSS
    # framework carries far more of them than prose. Dropping them keeps the
    # moderated text to what a visitor actually reads.
    document.css("script, style, noscript, template").each(&:remove)

    text = "Title: #{page.title} #{document.text} #{link_targets(document).join(" ")}".squish
    text = strip_seller_first_party_urls(text, page_seller(page))

    Result.new(
      text: text[0, MAX_PAGE_TEXT_LENGTH],
      image_urls: page_image_urls(document).first(MAX_PAGE_IMAGE_URLS)
    )
  end

  private
    # Where a page's links point. Kept as bare URLs so the blocklist's
    # word-boundary matching and the prompt strategies see the destination, and
    # so `strip_seller_first_party_urls` can neutralize the seller's own hosts
    # exactly as it does for a URL written into prose.
    def link_targets(document)
      document.css("a[href]").filter_map do |anchor|
        href = anchor["href"].to_s.strip
        href if href.start_with?("http://", "https://")
      end.uniq
    end

    # Only remotely-hosted images, and only ones a classifier can fetch. A
    # custom page's images are arbitrary URLs the seller wrote, so inline
    # `data:` images (which OpenAI cannot download from a URL) and relative
    # paths (which have no absolute form here) are left out rather than sent as
    # URLs that would 400 the moderation call.
    def page_image_urls(document)
      document.css("img[src]").filter_map do |img|
        src = img["src"].to_s.strip
        src if src.start_with?("http://", "https://")
      end.uniq
    end

    # A page belongs to a user (storefront/slugged pages) or a product (the
    # product page takeover); first-party host stripping needs the seller either
    # way.
    def page_seller(page)
      page.pageable.is_a?(User) ? page.pageable : page.pageable.try(:user)
    end

    # A seller linking to their OWN storefront/profile (or one of their own
    # product pages) is inherently first-party and must never be treated as
    # policy-violating content. Domain labels are arbitrary identifiers
    # (usernames, brand names) that can coincidentally contain a blocklisted
    # word as a boundary-delimited token, producing false positives such as a
    # bulk email being rejected for including the seller's own subdomain URL.
    # We neutralize only the scheme+host (the arbitrary domain label) of the
    # seller's own URLs, while PRESERVING any path/query text so user-controlled
    # content in a permalink or query string is still moderated. Third-party
    # URLs are left fully intact so genuine off-site abuse is still caught.
    def strip_seller_first_party_urls(text, seller)
      hosts = seller_first_party_hosts(seller)
      return text if hosts.empty?

      text.gsub(URI::DEFAULT_PARSER.make_regexp(%w[http https])) do |url|
        uri = begin
          URI.parse(url)
        rescue URI::InvalidURIError
          nil
        end
        next url unless uri&.host && hosts.include?(uri.host.downcase)

        # Drop scheme+host (the false-positive domain label); keep path/query/
        # fragment so any blocklisted term the seller put after the host is still
        # seen by the keyword/AI strategies.
        remainder = [uri.path.presence, uri.query.present? ? "?#{uri.query}" : nil,
                     uri.fragment.present? ? "##{uri.fragment}" : nil].compact.join
        remainder.presence || " "
      end
    end

    def seller_first_party_hosts(seller)
      return [] if seller.blank?

      # Only treat a custom domain as first-party when it is ACTIVE (verified +
      # valid cert) — matching UrlService#custom_domain_with_protocol. An alive
      # but unverified custom domain can be an arbitrary off-site URL the seller
      # set without proving ownership, so stripping it would let genuine off-site
      # links bypass moderation.
      custom_domain = seller.custom_domain&.active? ? seller.custom_domain.domain : nil

      [seller.subdomain, custom_domain]
        .compact_blank
        .filter_map { |value| normalize_host(value) }
        .uniq
    end

    # `subdomain` carries a `:port` in dev/test (e.g. "name.test.gumroad.com:31337")
    # while `URI.parse(url).host` never does, so normalize both sides to a bare,
    # port-less, scheme-less hostname before comparing.
    def normalize_host(value)
      URI.parse(value.include?("//") ? value : "//#{value}").host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    def product_image_urls(product)
      # Always use the ORIGINAL file URLs here, never display variants. The
      # default `url` styles trigger synchronous variant generation
      # (`file.variant(...).processed`), and this extractor runs inside the
      # product's save transaction (the content-moderation validation fires
      # during publish). Attaching a freshly generated variant inside a
      # transaction defers its upload to after_commit, by which point the
      # image-processing tempfile has been deleted — the upload then crashes
      # with Errno::ENOENT after the product row has already committed.
      # Moderation only needs the image contents, so the originals are both
      # safe and cheaper.
      cover_image_urls = product.display_asset_previews.joins(file_attachment: :blob)
                                .where(active_storage_blobs: { content_type: PERMITTED_IMAGE_TYPES })
                                .map { |preview| preview.url(style: :original) }

      thumbnail_image_urls = product.thumbnail.present? ? [product.thumbnail.url(variant: :original)] : []

      product_description_image_urls = Nokogiri::HTML(product.link.description).css("img").filter_map { |img| img["src"] }

      rich_contents = product.alive_rich_contents

      rich_content_file_image_urls = rich_contents.flat_map do |rich_content|
        ProductFile.where(id: rich_content.embedded_product_file_ids_in_order, filegroup: "image").filter_map do |product_file|
          signed_download_url_for_s3_key_and_filename(product_file.s3_key, product_file.s3_filename, expires_in: 1.hour)
        rescue Aws::S3::Errors::NotFound
          nil
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
      ).compact_blank
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
end
