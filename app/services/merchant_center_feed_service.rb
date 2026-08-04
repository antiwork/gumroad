# frozen_string_literal: true

# Builds the Google Merchant Center product feed (RSS 2.0 with the g: namespace,
# https://support.google.com/merchants/answer/7052112) and publishes it alongside the
# sitemaps in public storage. Eligibility intentionally mirrors Discover: a product that
# is not recommendable there should not be advertised in Shopping either.
class MerchantCenterFeedService
  FEED_KEY = "merchant-center/feed.xml"
  FEED_TITLE = "Gumroad products"
  # Google rejects descriptions over 5,000 characters.
  MAX_DESCRIPTION_LENGTH = 5_000
  # First-run safety bound; raise deliberately once feed size/ingest behavior is known.
  DEFAULT_MAX_PRODUCTS = 100_000
  # Hard bound on rows SCANNED (not accepted): a catalog dense with ineligible
  # products must not turn a small max_products into a full-table walk.
  MAX_SCANNED_PRODUCTS = 500_000

  # Same preload shape as SitemapService: keeps the per-row seller and cover lookups flat
  # across a full-catalog walk.
  FEED_PRELOADS = [
    :user,
    { display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } }
  ].freeze
  private_constant :FEED_PRELOADS

  def generate(max_products: DEFAULT_MAX_PRODUCTS)
    xml = build_xml(eligible_products(max_products))
    upload(xml)
    xml
  end

  def feed_url
    "#{PUBLIC_STORAGE_CDN_S3_PROXY_HOST}/#{FEED_KEY}"
  end

  private
    def eligible_products(max_products)
      products = []
      scanned = 0
      Link.alive.not_archived.preload(*FEED_PRELOADS).find_each do |product|
        break if products.size >= max_products
        scanned += 1
        break if scanned > MAX_SCANNED_PRODUCTS
        products << product if eligible?(product)
      end
      products
    end

    # recommendable? is the Discover gate (alive, not archived, taxonomy, sale made,
    # seller payable/compliant). The extra checks are Merchant Center requirements it
    # doesn't cover: no adult content, a nonzero price, and a real image resource
    # (social_share_image is the cover image, an oEmbed THUMBNAIL, or a video poster —
    # never the oEmbed iframe URL, which Merchant Center rejects for g:image_link).
    def eligible?(product)
      product.recommendable? &&
        !product.rated_as_adult? &&
        !product.user.suspended? &&
        product.price_cents.to_i.positive? &&
        product.social_share_image.present?
    end

    def build_xml(products)
      builder = Builder::XmlMarkup.new(indent: 2)
      builder.instruct!(:xml, version: "1.0", encoding: "UTF-8")
      builder.rss(version: "2.0", "xmlns:g": "http://base.google.com/ns/1.0") do
        builder.channel do
          builder.title FEED_TITLE
          builder.link UrlService.root_domain_with_protocol
          builder.description "Products for sale on Gumroad"
          products.each { |product| build_item(builder, product) }
        end
      end
      builder.target!
    end

    def build_item(builder, product)
      builder.item do
        builder.tag!("g:id", product.external_id)
        builder.tag!("g:title", product.name)
        builder.tag!("g:description", product.plaintext_description.truncate(MAX_DESCRIPTION_LENGTH))
        builder.tag!("g:link", product.long_url)
        builder.tag!("g:image_link", product.social_share_image)
        builder.tag!("g:price", formatted_price(product))
        builder.tag!("g:availability", "in stock")
        builder.tag!("g:brand", product.user.name_or_username)
        builder.tag!("g:condition", "new")
      end
    end

    def formatted_price(product)
      currency_code = product.price_currency_type.to_s.upcase
      if product.single_unit_currency?
        "#{product.price_cents} #{currency_code}"
      else
        format("%.2f %s", product.price_cents / 100.0, currency_code)
      end
    end

    def upload(xml)
      if upload_to_s3?
        Aws::S3::Client.new.put_object(
          bucket: PUBLIC_STORAGE_S3_BUCKET,
          key: FEED_KEY,
          body: xml,
          content_type: "application/xml"
        )
      else
        path = Rails.public_path.join(FEED_KEY)
        FileUtils.mkdir_p(path.dirname)
        File.write(path, xml)
      end
    end

    def upload_to_s3?
      Rails.env.production? || Rails.env.staging?
    end
end
