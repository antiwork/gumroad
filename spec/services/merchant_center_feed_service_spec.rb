# frozen_string_literal: true

require "spec_helper"

describe MerchantCenterFeedService do
  let(:service) { described_class.new }
  let(:feed_glob) { Rails.public_path.join("sitemap/merchant-center/feed*.xml") }

  before { FileUtils.rm_f(Dir[feed_glob]) }
  after { FileUtils.rm_f(Dir[feed_glob]) }

  def create_eligible_product(**attrs)
    product = create(:product, :recommendable, price_cents: 999, **attrs)
    create(:asset_preview, link: product)
    product.reload
  end

  # generate writes the feed file (the public path outside production) and returns the item count.
  def generate_xml(**options)
    FileUtils.rm_f(Rails.public_path.join(described_class::FEED_KEY))
    service.generate(**options)
    File.read(Rails.public_path.join(described_class::FEED_KEY))
  end

  def items(xml)
    Nokogiri::XML(xml).xpath("//item")
  end

  def g_field(item, name)
    item.at_xpath("g:#{name}", "g" => "http://base.google.com/ns/1.0")&.text
  end

  describe "#generate" do
    it "produces an RSS 2.0 feed with the Google Shopping fields" do
      product = create_eligible_product(name: "Great product", description: "<p>Rich <b>description</b></p>")

      xml = generate_xml

      doc = Nokogiri::XML(xml)
      expect(doc.root.name).to eq "rss"
      expect(doc.root["version"]).to eq "2.0"
      expect(doc.root.namespaces["xmlns:g"]).to eq "http://base.google.com/ns/1.0"

      item = items(xml).first
      expect(g_field(item, "id")).to eq product.external_id
      expect(g_field(item, "title")).to eq "Great product"
      expect(g_field(item, "description")).to eq "Rich description"
      expect(g_field(item, "link")).to eq product.long_url
      expect(g_field(item, "image_link")).to eq product.social_share_image
      expect(g_field(item, "price")).to eq "9.99 USD"
      expect(g_field(item, "availability")).to eq "in stock"
      expect(g_field(item, "brand")).to eq product.user.name_or_username
      expect(g_field(item, "condition")).to eq "new"
    end

    it "converts non-USD prices to USD with checkout's rate source" do
      create_eligible_product(price_currency_type: "eur", price_cents: 2600)
      Redis::Namespace.new(:currencies, redis: $redis).set("EUR", "0.81127")

      # 26.00 EUR at the cached rate (0.81127 EUR/USD) — same conversion
      # get_usd_cents performs at checkout.
      expect(g_field(items(generate_xml).first, "price")).to eq "32.05 USD"
    end

    it "emits free US shipping for digital products" do
      create_eligible_product

      shipping = items(generate_xml).first.at_xpath("g:shipping", "g" => "http://base.google.com/ns/1.0")
      expect(shipping.at_xpath("g:country", "g" => "http://base.google.com/ns/1.0").text).to eq "US"
      expect(shipping.at_xpath("g:price", "g" => "http://base.google.com/ns/1.0").text).to eq "0.00 USD"
    end

    it "omits the shipping element for physical products" do
      product = create_eligible_product
      # update_column: the :recommendable trait's review purchase has no shipping
      # address, so a validated flip to physical would fail on unrelated records.
      product.update_column(:flags, product.flags | Link.flag_mapping["flags"][:is_physical])
      product.reload

      item = items(generate_xml).first
      expect(item).to be_present
      expect(item.at_xpath("g:shipping", "g" => "http://base.google.com/ns/1.0")).to be_nil
    end

    it "excludes non-USD products when no conversion rate is available" do
      create_eligible_product(price_currency_type: "eur", price_cents: 2600)
      Redis::Namespace.new(:currencies, redis: $redis).del("EUR")

      expect(items(generate_xml)).to be_empty
    end

    it "excludes non-USD products rather than falling through to a live rate fetch on a cache miss" do
      create_eligible_product(price_currency_type: "eur", price_cents: 2600)
      Redis::Namespace.new(:currencies, redis: $redis).del("EUR")
      expect(service).not_to receive(:query_rate)

      service.generate
    end

    it "escapes XML-unsafe characters in product fields" do
      create_eligible_product(name: "Bells & <Whistles>")

      xml = generate_xml

      expect(xml).to include("Bells &amp; &lt;Whistles&gt;")
      expect(g_field(items(xml).first, "title")).to eq "Bells & <Whistles>"
    end

    it "decodes HTML entities in descriptions so the feed carries plain text" do
      create_eligible_product(description: "<p>Fish &amp; Chips — 100% café</p>")

      expect(g_field(items(generate_xml).first, "description")).to eq "Fish & Chips — 100% café"
    end

    it "truncates titles over Google's 150-character limit" do
      create_eligible_product(name: "a" * 151)

      title = g_field(items(generate_xml).first, "title")
      expect(title.length).to eq 150
    end

    it "excludes products that are not recommendable for Discover" do
      not_recommendable = create(:product, price_cents: 999)
      create(:asset_preview, link: not_recommendable)

      expect(items(generate_xml)).to be_empty
    end

    it "excludes deleted products" do
      product = create_eligible_product
      product.update!(deleted_at: Time.current)

      expect(items(generate_xml)).to be_empty
    end

    it "excludes adult products" do
      product = create_eligible_product
      product.update!(is_adult: true)

      expect(items(generate_xml)).to be_empty
    end

    it "excludes products from suspended sellers" do
      product = create_eligible_product
      allow_any_instance_of(User).to receive(:suspended?).and_return(true)
      product.reload

      expect(items(generate_xml)).to be_empty
    end

    it "excludes free products" do
      product = create_eligible_product
      product.update!(price_cents: 0, customizable_price: true)

      expect(items(generate_xml)).to be_empty
    end

    it "excludes products without an image" do
      create(:product, :recommendable, price_cents: 999)

      expect(items(generate_xml)).to be_empty
    end

    it "excludes products whose only preview is an oEmbed embed with no thumbnail" do
      product = create(:product, :recommendable, price_cents: 999)
      preview = create(:asset_preview_youtube, link: product)
      preview.oembed["info"].delete("thumbnail_url")
      preview.save!
      product.reload

      expect(items(generate_xml)).to be_empty
    end

    it "uses the oEmbed thumbnail, not the iframe URL, for oEmbed-preview products" do
      product = create(:product, :recommendable, price_cents: 999)
      create(:asset_preview_youtube, link: product)
      product.reload

      image_link = g_field(items(generate_xml).first, "image_link")
      expect(image_link).to eq product.social_share_image
      expect(image_link).not_to include("/embed/")
    end

    it "converts single-unit currency prices to USD" do
      create_eligible_product(price_currency_type: "jpy", price_cents: 500)
      Redis::Namespace.new(:currencies, redis: $redis).set("JPY", "78.3932")

      # 500 JPY at the cached rate (78.3932 JPY/USD).
      expect(g_field(items(generate_xml).first, "price")).to eq "6.38 USD"
    end

    it "keeps the feed under the sitemap uploader's allowed S3 prefix" do
      expect(described_class::FEED_KEY).to start_with("sitemap/")
    end

    it "writes to S3 with the sitemap uploader's ACL and content type when uploading" do
      create_eligible_product
      object = instance_double(Aws::S3::Object)
      allow(service).to receive_messages(upload_to_s3?: true, s3_client: instance_double(Aws::S3::Client))
      allow(Aws::S3::Object).to receive(:new).and_call_original
      allow(Aws::S3::Object).to receive(:new)
        .with(hash_including(bucket_name: PUBLIC_STORAGE_S3_BUCKET, key: described_class::FEED_KEY))
        .and_return(object)

      uploaded = nil
      expect(object).to receive(:upload_file).with(
        kind_of(String),
        hash_including(content_type: "application/xml", acl: "public-read", cache_control: "private, max-age=0, no-cache")
      ) { |path, _| uploaded = File.read(path) }

      service.generate

      expect(items(uploaded).size).to eq 1
    end

    it "caps the feed at max_products" do
      2.times { create_eligible_product }

      expect(items(generate_xml(max_products: 1)).size).to eq 1
    end

    it "bounds the catalog scan even when products are ineligible" do
      create(:product, :recommendable, price_cents: 999) # alive but imageless — never accepted
      create_eligible_product

      stub_const("#{described_class}::MAX_SCANNED_PRODUCTS", 1)

      # Scan stops after 1 row, so the eligible product created second is never reached.
      expect(items(generate_xml)).to be_empty
    end

    it "writes the feed to the public path outside production" do
      create_eligible_product

      service.generate

      path = Rails.public_path.join(described_class::FEED_KEY)
      expect(File.exist?(path)).to be true
      expect(File.read(path)).to include("<rss")
    end
  end

  describe "sharding" do
    def shard_xml(index)
      File.read(Rails.public_path.join(described_class.shard_key(index)))
    end

    def shard_ids(index)
      items(shard_xml(index)).map { |item| g_field(item, "id") }
    end

    # Two products in different shards: width = the second product's id puts the first in
    # shard 0 and the second in shard 1.
    def split_across_two_shards
      first = create_eligible_product
      second = create_eligible_product
      stub_const("#{described_class}::SHARD_WIDTH", second.id)
      [first, second]
    end


    describe ".shard_key" do
      it "zero-pads the index under the sitemap uploader's prefix" do
        expect(described_class.shard_key(0)).to eq "sitemap/merchant-center/feed-00.xml"
        expect(described_class.shard_key(14)).to eq "sitemap/merchant-center/feed-14.xml"
        expect(described_class.shard_key(7)).to start_with("sitemap/")
      end
    end

    describe ".last_shard_index" do
      it "is nil without products and otherwise the shard of the highest id" do
        expect(described_class.last_shard_index).to be_nil

        product = create_eligible_product
        stub_const("#{described_class}::SHARD_WIDTH", 1)

        expect(described_class.last_shard_index).to eq product.id
      end
    end

    describe "#generate_shard" do
      it "writes only the products in its id range, to its own file" do
        first, second = split_across_two_shards

        expect(service.generate_shard(0)).to eq 1
        expect(service.generate_shard(1)).to eq 1

        expect(shard_ids(0)).to eq [first.external_id]
        expect(shard_ids(1)).to eq [second.external_id]
        expect(File.exist?(Rails.public_path.join(described_class::FEED_KEY))).to be false
      end

      it "writes a valid empty feed for a range without eligible products" do
        create_eligible_product

        service.generate_shard(3)

        expect(Nokogiri::XML(shard_xml(3)).root.name).to eq "rss"
        expect(shard_ids(3)).to be_empty
      end

      it "does not scan products outside its range" do
        split_across_two_shards
        scanned = []
        allow_any_instance_of(described_class).to receive(:eligible?).and_wrap_original do |original, product|
          scanned << product.id
          original.call(product)
        end

        service.generate_shard(1)

        expect(scanned).to eq [Link.maximum(:id)]
      end

      it "fails without replacing the previous file when a shard passes the item guard" do
        2.times { create_eligible_product }
        path = Rails.public_path.join(described_class.shard_key(0))
        FileUtils.mkdir_p(path.dirname)
        File.write(path, "yesterday")
        stub_const("#{described_class}::SHARD_WIDTH", Link.maximum(:id) + 1)
        stub_const("#{described_class}::MAX_SHARD_ITEMS", 1)

        expect { service.generate_shard(0) }.to raise_error(described_class::ShardTooLarge)

        expect(File.read(path)).to eq "yesterday"
      end

      it "uploads the shard to its own S3 key" do
        create_eligible_product
        object = instance_double(Aws::S3::Object)
        allow(service).to receive_messages(upload_to_s3?: true, s3_client: instance_double(Aws::S3::Client))
        allow(Aws::S3::Object).to receive(:new).and_call_original
        expect(Aws::S3::Object).to receive(:new)
          .with(hash_including(bucket_name: PUBLIC_STORAGE_S3_BUCKET, key: "sitemap/merchant-center/feed-00.xml"))
          .and_return(object)
        expect(object).to receive(:upload_file).with(kind_of(String), hash_including(acl: "public-read"))

        service.generate_shard(0)
      end
    end

    describe "uploading" do
      let(:checked_in) { [] }
      let(:service) { described_class.new(on_upload: -> { checked_in << true }) }

      before do
        create_eligible_product
        stub_const("#{described_class}::UPLOAD_CHECK_IN_INTERVAL", 0)
        allow(service).to receive_messages(upload_to_s3?: true, s3_client: instance_double(Aws::S3::Client))
      end

      it "calls on_upload while the file uploads" do
        allow_any_instance_of(Aws::S3::Object).to receive(:upload_file) { |_object, _path, options| options[:progress_callback].call([1], [2]) }

        service.generate

        expect(checked_in.size).to eq 1
      end

      it "raises the callback's own error when the SDK wraps it in a multipart failure" do
        service = described_class.new(on_upload: -> { raise ArgumentError, "lock lost" })
        allow(service).to receive_messages(upload_to_s3?: true, s3_client: instance_double(Aws::S3::Client))
        allow_any_instance_of(Aws::S3::Object).to receive(:upload_file) do |_object, _path, options|
          options[:progress_callback].call([1], [2])
        rescue => e
          raise Aws::S3::MultipartUploadError.new("multipart upload failed: lock lost", [e])
        end

        expect { service.generate }.to raise_error(ArgumentError, "lock lost")
      end

      it "leaves a genuine upload failure as the SDK raised it" do
        allow_any_instance_of(Aws::S3::Object).to receive(:upload_file).and_raise(Aws::S3::MultipartUploadError.new("boom", []))

        expect { service.generate }.to raise_error(Aws::S3::MultipartUploadError, "boom")
      end
    end

    describe "batching" do
      before do
        3.times { create_eligible_product }
        stub_const("#{described_class}::BATCH_SIZE", 2)
      end

      it "reports progress after every batch" do
        reported = 0
        service = described_class.new(on_batch: -> { reported += 1 })

        expect(service.generate).to eq 3

        expect(reported).to eq 2
      end

      it "stops without writing when the batch callback raises" do
        service = described_class.new(on_batch: -> { raise "stop" })

        expect { service.generate }.to raise_error("stop")

        expect(File.exist?(Rails.public_path.join(described_class::FEED_KEY))).to be false
      end

      it "does not wait on replicas for the legacy feed" do
        stub_const("REPLICAS_HOSTS", ["replica"])
        expect(ReplicaLagWatcher).not_to receive(:lagging?)

        service.generate
      end

      context "when walking a shard against replicas" do
        before do
          stub_const("REPLICAS_HOSTS", ["replica"])
          allow(ReplicaLagWatcher).to receive(:connect_to_replicas)
          allow(service).to receive(:sleep)
        end

        it "checks replica lag after every batch" do
          stub_const("#{described_class}::SHARD_WIDTH", Link.maximum(:id) + 1)
          expect(ReplicaLagWatcher).to receive(:lagging?).twice.and_return(false)

          service.generate_shard(0)
        end

        it "keeps reporting progress while replicas lag, then continues" do
          stub_const("#{described_class}::SHARD_WIDTH", Link.maximum(:id) + 1)
          lag = [true, true, false, false]
          allow(ReplicaLagWatcher).to receive(:lagging?) { lag.shift }
          reported = 0
          service = described_class.new(on_batch: -> { reported += 1 })
          allow(service).to receive(:sleep)

          expect(service.generate_shard(0)).to eq 3

          expect(reported).to eq 4
        end

        it "gives up instead of waiting past its limit, and publishes nothing" do
          stub_const("#{described_class}::SHARD_WIDTH", Link.maximum(:id) + 1)
          stub_const("#{described_class}::MAX_REPLICA_LAG_WAIT", -1)
          allow(ReplicaLagWatcher).to receive(:lagging?).and_return(true)

          expect { service.generate_shard(0) }.to raise_error(described_class::ReplicaLagTimeout)

          expect(File.exist?(Rails.public_path.join(described_class.shard_key(0)))).to be false
        end
      end
    end
  end

  describe "query cost" do
    def sql_during(&block)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      queries
    end

    it "does not look up sales for a product a query-free check rejects" do
      product = create_eligible_product
      product.update!(price_cents: 0, customizable_price: true)

      queries = sql_during { expect(service.generate).to eq 0 }

      expect(queries.grep(/FROM `purchases`/)).to be_empty
    end

    it "does not look up sales for a product without a preview" do
      create(:product, :recommendable, price_cents: 999)

      queries = sql_during { expect(service.generate).to eq 0 }

      expect(queries.grep(/FROM `purchases`/)).to be_empty
    end

    it "does not resolve the cover image of a product that fails the Discover checks" do
      product = create(:product, price_cents: 999)
      create(:asset_preview, link: product)
      resolved = 0
      allow_any_instance_of(Link).to receive(:social_share_image).and_wrap_original do |original|
        resolved += 1
        original.call
      end

      expect(service.generate).to eq 0

      expect(resolved).to eq 0
    end

    it "loads taxonomies once per batch, not once per product" do
      3.times { create_eligible_product(taxonomy: create(:taxonomy)) }

      queries = sql_during { expect(service.generate).to eq 3 }

      expect(queries.grep(/FROM `taxonomies`/).size).to eq 1
    end

    it "loads prices once per batch, not once per product" do
      3.times { create_eligible_product }

      queries = sql_during { expect(service.generate).to eq 3 }

      expect(queries.grep(/FROM `prices`/).size).to eq 1
    end
  end
end
