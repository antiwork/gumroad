# frozen_string_literal: true

# Builds the Google Merchant Center product feed (RSS 2.0 with the g: namespace,
# https://support.google.com/merchants/answer/7052112) and publishes it alongside the
# sitemaps in public storage. Eligibility intentionally mirrors Discover: a product that
# is not recommendable there should not be advertised in Shopping either.
class MerchantCenterFeedService
  include CurrencyHelper

  FEED_KEY = "sitemap/merchant-center/feed.xml"
  FEED_TITLE = "Gumroad products"
  # Google rejects descriptions over 5,000 characters.
  MAX_DESCRIPTION_LENGTH = 5_000
  # Google truncates (and may warn on) titles over 150 characters.
  MAX_TITLE_LENGTH = 150
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
    @usd_rates = {}
    xml = build_xml(max_products)
    upload(xml)
    xml
  end

  def feed_url
    "#{PUBLIC_STORAGE_CDN_S3_PROXY_HOST}/#{FEED_KEY}"
  end

  private
    # Streams eligible rows straight into the builder instead of accumulating them:
    # holding up to max_products Links (plus their preloaded seller/cover chains) in an
    # array would dominate the job's memory; find_each batches are droppable this way.
    # The scan cap lives on the relation (find_each honors limit since Rails 6.1) so it
    # bounds rows FETCHED from the catalog, not just rows the block gets to see.
    def each_eligible_product(max_products)
      accepted = 0
      Link.alive.not_archived.limit(MAX_SCANNED_PRODUCTS).preload(*FEED_PRELOADS).find_each do |product|
        break if accepted >= max_products
        if eligible?(product)
          accepted += 1
          yield product
        end
      end
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
        usd_price_cents(product).to_i.positive? &&
        product.social_share_image.present?
    end

    def build_xml(max_products)
      builder = Builder::XmlMarkup.new(indent: 2)
      builder.instruct!(:xml, version: "1.0", encoding: "UTF-8")
      builder.rss(version: "2.0", "xmlns:g": "http://base.google.com/ns/1.0") do
        builder.channel do
          builder.title FEED_TITLE
          builder.link UrlService.root_domain_with_protocol
          builder.description "Products for sale on Gumroad"
          each_eligible_product(max_products) { |product| build_item(builder, product) }
        end
      end
      builder.target!
    end

    def build_item(builder, product)
      builder.item do
        builder.tag!("g:id", product.external_id)
        builder.tag!("g:title", feed_title(product))
        builder.tag!("g:description", feed_description(product))
        builder.tag!("g:link", product.long_url)
        builder.tag!("g:image_link", product.social_share_image)
        builder.tag!("g:price", feed_price(product))
        builder.tag!("g:availability", "in stock")
        builder.tag!("g:brand", product.user.name_or_username)
        builder.tag!("g:condition", "new")
        build_shipping(builder, product)
      end
    end

    # Digital products ship nowhere; a free-US <g:shipping> entry clears Merchant
    # Center's "Missing shipping information" requirement (US is the primary target
    # country) without account-level shipping settings. Physical products get no
    # entry — their real shipping cost is seller-configured and unknown here.
    def build_shipping(builder, product)
      return if product.is_physical?

      builder.tag!("g:shipping") do
        builder.tag!("g:country", "US")
        builder.tag!("g:price", "0.00 USD")
      end
    end

    # plaintext_description strips tags but leaves HTML entities encoded ("Fish &amp;
    # Chips"); decode them so Builder's XML escaping is the only encoding layer —
    # otherwise Google renders the literal "&amp;".
    def feed_description(product)
      CGI.unescapeHTML(product.plaintext_description).truncate(MAX_DESCRIPTION_LENGTH)
    end

    def feed_title(product)
      product.name.truncate(MAX_TITLE_LENGTH)
    end

    # Named feed_price, not formatted_price: CurrencyHelper#formatted_price(currency, price)
    # is included here and format_just_price_in_cents calls it with two args.
    #
    # Merchant Center rejected the original own-currency prices with "Unsupported
    # currency": the account's target countries each accept only their local currency,
    # and US free listings require USD. Feed prices are therefore converted to USD with
    # the same rate source checkout settles non-USD purchases with (get_usd_cents), so
    # the feed amount corresponds to what a buyer is actually charged.
    def feed_price(product)
      format("%.2f USD", usd_price_cents(product) / 100.0)
    end

    # Rates are memoized per feed run: one Redis lookup per currency instead of one per
    # product, and every item in a run converts at the same rate.
    #
    # cached_rate, not get_rate: the landing page's structured data reads cache-only too
    # (Product::StructuredData#usd_offer_price_cents), so a rate cache miss excludes the
    # product from the feed instead of showing a different price there than on its own page.
    def usd_price_cents(product)
      currency = product.price_currency_type.to_s.downcase
      return product.price_cents if currency == "usd"

      rate = @usd_rates.fetch(currency) do
        @usd_rates[currency] = begin
          cached_rate(currency)
        rescue StandardError => e
          Rails.logger.error("MerchantCenterFeedService: no USD rate for #{currency}, excluding its products (#{e.class}: #{e.message})")
          nil
        end
      end
      return nil if rate.to_f <= 0

      get_usd_cents(currency, product.price_cents, rate:)
    end

    def upload(xml)
      if upload_to_s3?
        s3_client.put_object(
          bucket: PUBLIC_STORAGE_S3_BUCKET,
          key: FEED_KEY,
          body: xml,
          content_type: "application/xml",
          acl: "public-read",
          cache_control: "private, max-age=0, no-cache"
        )
      else
        path = Rails.public_path.join(FEED_KEY)
        FileUtils.mkdir_p(path.dirname)
        File.write(path, xml)
      end
    end

    # Same uploader identity, ACL, and cache headers as the sitemap writes to this
    # bucket (SitemapGenerator::AwsSdkAdapter defaults); the web app's default AWS
    # credentials are not guaranteed PutObject on the public storage bucket.
    def s3_client
      Aws::S3::Client.new(
        credentials: Aws::Credentials.new(
          GlobalConfig.get("S3_SITEMAP_UPLOADER_ACCESS_KEY"),
          GlobalConfig.get("S3_SITEMAP_UPLOADER_SECRET_ACCESS_KEY")
        )
      )
    end

    def upload_to_s3?
      Rails.env.production? || Rails.env.staging?
    end
end
