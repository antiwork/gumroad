# frozen_string_literal: true

# Builds the Google Merchant Center product feed (RSS 2.0 with the g: namespace,
# https://support.google.com/merchants/answer/7052112) and publishes it alongside the
# sitemaps in public storage. Eligibility intentionally mirrors Discover: a product that
# is not recommendable there should not be advertised in Shopping either.
class MerchantCenterFeedService
  include CurrencyHelper

  FEED_KEY = "sitemap/merchant-center/feed.xml"
  SHARD_KEY_PREFIX = "sitemap/merchant-center/feed-"
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
  # Shard N holds the products with ids in [N * SHARD_WIDTH, (N + 1) * SHARD_WIDTH). A fixed id
  # range keeps a product in the same file from run to run and keeps shards disjoint, so no
  # g:id appears in two sources.
  SHARD_WIDTH = 1_000_000
  # A shard over this size fails the run instead of publishing a truncated file; the answer is a
  # narrower SHARD_WIDTH, not a silent cut.
  MAX_SHARD_ITEMS = 150_000
  # Rows per query. Shard walks check replica lag between batches.
  BATCH_SIZE = 1_000
  # Longest a shard walk waits for lagging replicas. Below the run's lock TTL, so a stall fails
  # the shard job (and Sidekiq retries it) instead of costing the run its lock.
  MAX_REPLICA_LAG_WAIT = 10.minutes

  class ShardTooLarge < StandardError; end
  class ReplicaLagTimeout < StandardError; end

  def self.shard_key(index) = format("%s%02d.xml", SHARD_KEY_PREFIX, index)

  # Largest shard index that can hold a product today. Primary-key read, no scan.
  def self.last_shard_index
    max_id = Link.maximum(:id)
    max_id ? max_id / SHARD_WIDTH : nil
  end

  # Same preload shape as SitemapService: keeps the per-row seller and cover lookups flat
  # across a full-catalog walk.
  FEED_PRELOADS = [
    :user,
    { display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } }
  ].freeze
  private_constant :FEED_PRELOADS

  # on_batch runs after every batch of scanned rows and while waiting on replicas; the run uses
  # it to hold its lock and to honor the kill switch.
  def initialize(on_batch: nil)
    @on_batch = on_batch
  end

  # The legacy feed: the first MAX_SCANNED_PRODUCTS alive rows by id, at most max_products accepted.
  # This is the only file Merchant Center reads until a shard source is registered by hand.
  # Returns the number of items written.
  def generate(max_products: DEFAULT_MAX_PRODUCTS)
    @usd_rates = {}
    publish(FEED_KEY) do |emit|
      each_eligible_product(Link.alive.not_archived.limit(MAX_SCANNED_PRODUCTS), max_products:, wait_for_lag: false, &emit)
    end
  end

  # One id-range shard, written to its own object. A failure before the upload leaves the
  # previous object in place. Rates stay memoized across the shards of one service instance, so a
  # run converts at one rate. Returns the number of items written.
  def generate_shard(index)
    @usd_rates ||= {}
    first_id = index * SHARD_WIDTH
    scope = Link.alive.not_archived.where(id: first_id...(first_id + SHARD_WIDTH))
    publish(self.class.shard_key(index), max_items: MAX_SHARD_ITEMS) do |emit|
      each_eligible_product(scope, wait_for_lag: true, &emit)
    end
  end

  def feed_url
    "#{PUBLIC_STORAGE_CDN_S3_PROXY_HOST}/#{FEED_KEY}"
  end

  private
    # Streams eligible rows straight into the file instead of accumulating them: holding every
    # accepted Link (plus its preloaded seller/cover chain) in an array would dominate the
    # job's memory; batches are droppable this way.
    # A limit on the relation (find_in_batches honors it) bounds rows FETCHED from the
    # catalog, not just rows the block gets to see.
    # The legacy feed has never waited on replicas, so it still doesn't: only shard walks add
    # read load the old run did not have.
    def each_eligible_product(scope, max_products: nil, wait_for_lag:)
      accepted = 0
      scope.preload(*FEED_PRELOADS).find_in_batches(batch_size: BATCH_SIZE) do |batch|
        batch.each do |product|
          return if max_products && accepted >= max_products
          if eligible?(product)
            accepted += 1
            yield product
          end
        end
        wait_for_replicas if wait_for_lag
        @on_batch&.call
      end
    end

    # ReplicaLagWatcher.watch sleeps without limit and renews nothing, so wait here instead.
    def wait_for_replicas
      return if REPLICAS_HOSTS.empty?

      ReplicaLagWatcher.connect_to_replicas
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_REPLICA_LAG_WAIT
      while ReplicaLagWatcher.lagging?(ReplicaLagWatcher::DEFAULT_OPTIONS.merge(silence: true))
        raise ReplicaLagTimeout, "replicas still lagging after #{MAX_REPLICA_LAG_WAIT.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        @on_batch&.call
        sleep ReplicaLagWatcher::DEFAULT_OPTIONS.fetch(:sleep)
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

    # Builds the document in a Tempfile and uploads it from there, so memory stays flat however
    # large the feed grows. The block receives an emit callable for each eligible product.
    def publish(key, max_items: nil)
      Tempfile.create(["merchant-center-feed", ".xml"], binmode: true) do |file|
        items = 0
        builder = Builder::XmlMarkup.new(indent: 2, target: file)
        builder.instruct!(:xml, version: "1.0", encoding: "UTF-8")
        builder.rss(version: "2.0", "xmlns:g": "http://base.google.com/ns/1.0") do
          builder.channel do
            builder.title FEED_TITLE
            builder.link UrlService.root_domain_with_protocol
            builder.description "Products for sale on Gumroad"
            yield(lambda do |product|
              items += 1
              raise ShardTooLarge, "#{key} passed #{max_items} items" if max_items && items > max_items
              build_item(builder, product)
            end)
          end
        end
        file.close
        upload(file.path, key)
        items
      end
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

    def feed_description(product)
      product.plaintext_description.truncate(MAX_DESCRIPTION_LENGTH)
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

    def upload(source_path, key)
      if upload_to_s3?
        # upload_file switches to a multipart upload for large files and publishes the object
        # only when it completes.
        Aws::S3::Object.new(bucket_name: PUBLIC_STORAGE_S3_BUCKET, key:, client: s3_client).upload_file(
          source_path,
          content_type: "application/xml",
          acl: "public-read",
          cache_control: "private, max-age=0, no-cache"
        )
      else
        path = Rails.public_path.join(key)
        FileUtils.mkdir_p(path.dirname)
        FileUtils.cp(source_path, path)
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
