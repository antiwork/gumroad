# frozen_string_literal: true

require "spec_helper"

describe Pages::ProfileData do
  describe ".build" do
    let(:seller) { create(:user) }

    context "when the seller has no saved profile row" do
      before do
        SellerProfile.where(seller_id: seller.id).delete_all
        seller.reload
      end

      it "returns an empty pages list without raising" do
        expect(Pages::ProfileData.build(seller)[:pages]).to eq([])
      end

      it "does not build a seller_profile on the seller as a side effect" do
        Pages::ProfileData.build(seller)

        expect(seller.association(:seller_profile)).not_to be_loaded
        expect(SellerProfile.exists?(seller_id: seller.id)).to be(false)
      end
    end

    context "when the seller has profile tabs" do
      before do
        seller.seller_profile.json_data["tabs"] = [{ "name" => "Shop", "sections" => [] }, { "name" => "", "sections" => [] }]
        seller.seller_profile.save!
      end

      it "returns only the named tabs" do
        expect(Pages::ProfileData.build(seller.reload)[:pages]).to eq([{ name: "Shop" }])
      end
    end

    describe "seller_rating" do
      it "is absent when the seller_reputation_summary flag is off" do
        expect(Pages::ProfileData.build(seller)).not_to have_key(:seller_rating)
      end

      it "carries the summary when the flag is on and thresholds are met" do
        Feature.activate_user(:seller_reputation_summary, seller)
        summary = { average: 4.8, count: 12, products_count: 2 }
        allow_any_instance_of(User).to receive(:seller_reputation_summary).and_return(summary)

        expect(Pages::ProfileData.build(seller)[:seller_rating]).to eq(summary)
      end

      it "expires the cached payload so a lost Redis bump cannot pin seller_rating forever" do
        # Stub the rollup so this example only sees the outer payload TTL. A
        # lost INCR leaves the cache key unchanged; without expires_in the
        # second summary would never appear.
        Feature.activate_user(:seller_reputation_summary, seller)
        allow_any_instance_of(User).to receive(:seller_reputation_summary)
          .and_return({ average: 4.8, count: 12, products_count: 2 })

        expect(Pages::ProfileData.build(seller)[:seller_rating][:average]).to eq(4.8)

        allow_any_instance_of(User).to receive(:seller_reputation_summary)
          .and_return({ average: 3.1, count: 12, products_count: 2 })
        expect(Pages::ProfileData.build(seller)[:seller_rating][:average]).to eq(4.8)

        travel(Pages::ProfileData::CACHE_TTL + 1.second) do
          expect(Pages::ProfileData.build(seller)[:seller_rating][:average]).to eq(3.1)
        end
      end

      it "changes the cache key when a qualifying review stat moves through the write funnel" do
        # The cache key tracks a per-seller version bumped ONLY by the review-stat write
        # funnel (Product::ReviewStat), the single production writer of the counters
        # (gumroad-private#2384). A direct stat write without the funnel does not move it.
        Feature.activate_user(:seller_reputation_summary, seller)
        product = create(:product, user: seller)
        seller_profile = SellerProfile.find_by(seller_id: seller.id)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)

        product.update_review_stat_via_rating_change(nil, 5)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
      end

      it "changes the cache key for two review-stat mutations in the same second" do
        # A naive timestamp-based key has second precision and would reuse the same value
        # for both writes below; the funnel uses a monotonic Redis version so the second
        # bump must still move the key (the rollup it guards is recomputed after each).
        Feature.activate_user(:seller_reputation_summary, seller)
        product = create(:product, user: seller)
        seller_profile = SellerProfile.find_by(seller_id: seller.id)
        product.update_review_stat_via_rating_change(nil, 5)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)

        product.update_review_stat_via_rating_change(5, 4)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
      end

      it "does not change the cache key when a review-hidden product's stat mutates" do
        Feature.activate_user(:seller_reputation_summary, seller)
        product = create(:product, user: seller, display_product_reviews: false)
        stat = ProductReviewStat.create!(link: product, reviews_count: 1, average_rating: 5, ratings_of_five_count: 1)
        seller_profile = SellerProfile.find_by(seller_id: seller.id)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)

        stat.update!(reviews_count: 2, ratings_of_five_count: 2)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).to eq(key_before)
      end

      it "does not change the cache key when a zero-review stat's non-count fields mutate" do
        Feature.activate_user(:seller_reputation_summary, seller)
        product = create(:product, user: seller)
        stat = ProductReviewStat.create!(link: product, reviews_count: 0)
        seller_profile = SellerProfile.find_by(seller_id: seller.id)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)

        stat.update!(average_rating: 3.2)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).to eq(key_before)
      end
    end

    it "does not expose draft products in the public profile data payload" do
      published_product = create(:product, user: seller, name: "Published product", draft: false)
      draft_product = create(:product, user: seller, name: "Draft product", draft: true)

      products = Pages::ProfileData.build(seller)[:products]

      expect(products.pluck(:name)).to include(published_product.name)
      expect(products.pluck(:name)).not_to include(draft_product.name)
    end

    it "changes the cache key when a thumbnail is added or removed" do
      # Each of these reads mimics a fresh request: reload so the seller's products association
      # re-reads its cache version from the database instead of reusing the memoized one.
      product = create(:product, user: seller)
      seller_profile = SellerProfile.find_by(seller_id: seller.id)
      key_without_thumbnail = Pages::ProfileData.cache_key(seller.reload, seller_profile)
      expect(Pages::ProfileData.build(seller.reload)[:products].first[:thumbnail_url]).to be_nil

      thumbnail = Thumbnail.new(product:)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!

      key_with_thumbnail = Pages::ProfileData.cache_key(seller.reload, seller_profile)
      expect(key_with_thumbnail).not_to eq(key_without_thumbnail)
      expect(Pages::ProfileData.build(seller.reload)[:products].first[:thumbnail_url]).to be_present

      thumbnail.mark_deleted!

      expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_with_thumbnail)
      expect(Pages::ProfileData.build(seller.reload)[:products].first[:thumbnail_url]).to be_nil
    end

    describe "price staleness (gumroad-private#1518)" do
      # The payload's `price` comes from Link#price_formatted_verbose, which resolves through
      # the `prices` and variant rows rather than the links.price_cents column — but the cache
      # key derives from MAX(links.updated_at). Each example asserts the key moves AND that the
      # rebuilt payload serves the new price, since a moved key that still renders the old
      # value would be the same seller-visible bug.
      let(:seller_profile) { SellerProfile.find_by(seller_id: seller.id) }

      def payload_price
        Pages::ProfileData.build(seller.reload)[:products].first[:price]
      end

      it "rebuilds when a simple product's price changes" do
        product = create(:product, user: seller, price_cents: 3900)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)
        expect(payload_price).to eq("$39")

        product.update!(price_cents: 2900)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
        expect(payload_price).to eq("$29")
      end

      it "rebuilds when a tiered membership's tier price changes" do
        product = create(:membership_product_with_preset_tiered_pricing, user: seller)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)
        expect(payload_price).to eq("$3+ a month")

        product.tiers.first.prices.alive.is_buy.first.update!(price_cents: 500)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
        expect(payload_price).to eq("$5+ a month")
      end

      it "rebuilds when a variant's price difference changes" do
        product = create(:product, user: seller, price_cents: 1000)
        category = create(:variant_category, link: product)
        variant = create(:variant, variant_category: category, price_difference_cents: 500)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)
        expect(payload_price).to eq("$15")

        variant.update!(price_difference_cents: 900)

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
        expect(payload_price).to eq("$19")
      end

      it "rebuilds when a tier grouping is soft-deleted" do
        # Link#tier_category is scoped `alive`, so deleting the grouping drops the displayed
        # price to the $0 fallback — a price move with no write to `prices` at all.
        product = create(:membership_product_with_preset_tiered_pricing, user: seller)
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)
        expect(payload_price).to eq("$3+ a month")

        product.variant_categories.first.mark_deleted!

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
        expect(payload_price).to eq("$0 a month")
      end

      it "rebuilds when the editor's deletion sweep soft-deletes a variant" do
        # The editor stamps deletions with `update_all`, which skips callbacks, so
        # TouchesProductForPriceCache never fires for the deleted rows. Whether the key moves
        # anyway depends on a *survivor* write happening in the same save (a shifted
        # position_in_category, a renamed grouping) — incidental, and absent when the seller
        # deletes the last-positioned option and changes nothing else. Asserted against the
        # deletion primitive so the guarantee does not rest on that coincidence.
        product = create(:product, user: seller, price_cents: 1000)
        category = create(:variant_category, link: product, title: "Sizes")
        create(:variant, variant_category: category, name: "Large", price_difference_cents: 900)
        cheapest = create(:variant, variant_category: category, name: "Small", price_difference_cents: 0)
        service = Product::VariantCategoryUpdaterService.new(product:, category_params: { id: category.external_id })
        service.variant_category = category
        key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)

        service.send(:batch_delete_variants, [cheapest])

        expect(cheapest.reload.deleted_at).to be_present
        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(key_before)
      end

      it "touches the product from every association the displayed price resolves through" do
        # The guard that would have caught this class at gp#1398 time instead of one model at a
        # time: a new price-bearing association added without a touch fails here.
        product = create(:membership_product_with_preset_tiered_pricing, user: seller)
        tier = product.tiers.first
        # Created up front: creating a product inside the loop moves the key by itself
        # (cache_key_with_version embeds the relation's row count), so the Price arm would
        # pass with the touch reverted.
        simple_product = create(:product, user: seller)

        writes = {
          "Price" => -> { simple_product.prices.alive.first.update!(price_cents: 111) },
          "VariantPrice" => -> { tier.prices.alive.is_buy.first.update!(price_cents: 222) },
          "BaseVariant" => -> { tier.update!(name: "Renamed tier") },
          "VariantCategory" => -> { product.variant_categories.first.update!(title: "Renamed grouping") },
        }

        writes.each do |model, write|
          key_before = Pages::ProfileData.cache_key(seller.reload, seller_profile)
          write.call
          expect(Pages::ProfileData.cache_key(seller.reload, seller_profile))
            .not_to(eq(key_before), "#{model} write did not move the ProfileData cache key")
        end
      end
    end

    context "product images" do
      it "emits the thumbnail and the first image cover for each product" do
        product = create(:product, user: seller)
        thumbnail = create(:thumbnail, product:)
        create(:asset_preview_mov, link: product)
        cover = create(:asset_preview, link: product)

        entry = Pages::ProfileData.build(seller.reload)[:products].first

        expect(entry[:thumbnail_url]).to eq(thumbnail.url)
        expect(entry[:cover_url]).to eq(cover.url)
      end

      it "emits a cover_url for a product with no thumbnail so the card still has an image" do
        product = create(:product, user: seller)
        cover = create(:asset_preview, link: product)

        entry = Pages::ProfileData.build(seller.reload)[:products].first

        expect(entry[:thumbnail_url]).to be_nil
        expect(entry[:cover_url]).to eq(cover.url)
      end

      it "emits both keys as nil when the product has no thumbnail and no covers" do
        create(:product, user: seller)

        entry = Pages::ProfileData.build(seller.reload)[:products].first

        expect(entry).to have_key(:cover_url)
        expect(entry[:thumbnail_url]).to be_nil
        expect(entry[:cover_url]).to be_nil
      end

      it "skips non-image covers, which cannot go in an img tag" do
        product = create(:product, user: seller)
        create(:asset_preview_mov, link: product)

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:cover_url]).to be_nil
      end

      it "skips Unsplash-hosted images, which the custom-page CSP blocks" do
        product = create(:product, user: seller)
        create(:unsplash_thumbnail, product:)
        create(:asset_preview, link: product, unsplash_url: "https://images.unsplash.com/photo-1587502536575-6dfba0a6e017", attach: false)

        entry = Pages::ProfileData.build(seller.reload)[:products].first

        expect(entry[:thumbnail_url]).to be_nil
        expect(entry[:cover_url]).to be_nil
      end

      it "picks up a newly added cover rather than serving the cached payload" do
        product = create(:product, user: seller)
        expect(Pages::ProfileData.build(seller.reload)[:products].first[:cover_url]).to be_nil

        cover = create(:asset_preview, link: product)

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:cover_url]).to eq(cover.url)
      end
    end

    context "when the seller changes their username" do
      it "invalidates the cache so product URLs use the new subdomain" do
        create(:product, user: seller, name: "My product")

        original_urls = Pages::ProfileData.build(seller)[:products].pluck(:url)
        expect(original_urls).to all(include(seller.username))

        old_username = seller.username
        new_username = "renamed#{SecureRandom.hex(4)}"
        seller.update!(username: new_username)

        refreshed_urls = Pages::ProfileData.build(seller.reload)[:products].pluck(:url)
        expect(refreshed_urls).to all(include(new_username))
        expect(refreshed_urls.join).not_to include(old_username)
      end

      it "changes the cache key when the username changes" do
        seller_profile = SellerProfile.find_by(seller_id: seller.id)
        old_key = Pages::ProfileData.cache_key(seller, seller_profile)

        seller.update!(username: "renamed#{SecureRandom.hex(4)}")

        expect(Pages::ProfileData.cache_key(seller.reload, seller_profile)).not_to eq(old_key)
      end
    end

    context "when the seller has a live custom domain" do
      let!(:product) { create(:product, user: seller, name: "My product") }
      let!(:post) { create(:audience_post, :published, seller:, link: nil, shown_on_profile: true, slug: "my-update") }

      it "builds product and post URLs on the custom domain, not the subdomain" do
        custom_domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        custom_domain.set_routability!(true)

        payload = Pages::ProfileData.build(seller.reload)

        expect(payload[:products].first[:url]).to eq("#{PROTOCOL}://shop.example.com/l/#{product.general_permalink}")
        expect(payload[:posts].first[:url]).to start_with("#{PROTOCOL}://shop.example.com/p/")
        expect(payload.to_json).not_to include(seller.subdomain)
      end

      it "stays on the subdomain when only the configured domain's apex points to Gumroad" do
        custom_domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "www.example.com")
        custom_domain.set_routability!(false)

        payload = Pages::ProfileData.build(seller.reload)

        expect(payload[:products].first[:url]).to include(seller.subdomain)
        expect(payload[:posts].first[:url]).to include(seller.subdomain)
        expect(payload.to_json).not_to include("www.example.com")
      end

      it "stays on the subdomain while the domain is only verified, with no certificate yet" do
        create(:custom_domain, user: seller, domain: "shop.example.com", state: "verified")

        payload = Pages::ProfileData.build(seller.reload)

        expect(payload[:products].first[:url]).to include(seller.subdomain)
        expect(payload[:posts].first[:url]).to include(seller.subdomain)
      end

      it "moves the URLs off the old host when the domain goes live after the payload was cached" do
        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include(seller.subdomain)

        custom_domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        custom_domain.set_routability!(true)

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include("shop.example.com")
      end

      it "moves the URLs back to the subdomain when the domain is removed" do
        custom_domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        custom_domain.set_routability!(true)
        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include("shop.example.com")

        custom_domain.mark_deleted!

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include(seller.subdomain)
      end

      it "keeps the emitted host inside the navigation bridge's allowlist" do
        custom_domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        custom_domain.set_routability!(true)
        seller.reload

        payload = Pages::ProfileData.build(seller)
        hosts = (payload[:products] + payload[:posts]).map { URI(_1[:url]).host }.uniq

        expect(hosts).to all(be_in(seller.custom_html_store_hostnames))
      end

      it "ignores a custom domain belonging to one of the seller's products" do
        create(:custom_domain, :verified_with_certificate, user: nil, product:, domain: "oneproduct.example.com")

        payload = Pages::ProfileData.build(seller.reload)

        expect(payload[:products].first[:url]).to include(seller.subdomain)
        expect(payload.to_json).not_to include("oneproduct.example.com")
      end

      it "leaves the custom-domain host behind when the certificate expires with no DB write" do
        domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        domain.set_routability!(true)
        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include("shop.example.com")

        # active? goes false purely by the clock, so the domain row's updated_at never moves.
        domain.update_columns(ssl_certificate_issued_at: (CustomDomain::CERTIFICATE_LIFETIME + 1.day).ago)

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include(seller.subdomain)
      end
    end

    context "when the seller has neither a subdomain nor a live custom domain" do
      # A nil store host keeps posts on /:username/p/:slug rather than the invalid
      # gumroad.com/p/:slug route.
      it "does not build post URLs on the shared root domain" do
        create(:product, user: seller, name: "My product")
        create(:audience_post, :published, seller:, link: nil, shown_on_profile: true, slug: "my-update")
        allow_any_instance_of(User).to receive(:subdomain_with_protocol).and_return(nil)

        payload = Pages::ProfileData.build(seller.reload)

        expect(payload[:posts].first[:url]).not_to start_with("#{UrlService.domain_with_protocol}/p/")
      end
    end

    it "does not serve a stale prior-version payload" do
      seller_profile = SellerProfile.find_by(seller_id: seller.id)
      current_key = Pages::ProfileData.cache_key(seller, seller_profile)
      prior_key = current_key.sub("profile_data/#{Pages::ProfileData::CACHE_VERSION}/", "profile_data/v6/")
      Rails.cache.write(prior_key, { products: [], posts: [], pages: [] })

      data = Pages::ProfileData.build(seller)

      expect(current_key).to start_with("profile_data/#{Pages::ProfileData::CACHE_VERSION}/")
      expect(current_key).not_to eq(prior_key)
      expect(data).to include(products_total: 0, posts_total: 0)
    end

    context "when the catalogue exceeds MAX_ITEMS" do
      before { stub_const("Pages::ProfileData::MAX_ITEMS", 2) }

      it "reports the true total alongside the capped array" do
        3.times { create(:product, user: seller) }

        data = Pages::ProfileData.build(seller.reload)

        expect(data[:products].length).to eq(2)
        expect(data[:products_total]).to eq(3)
      end

      it "reports the true post total alongside the capped array" do
        3.times { create(:audience_installment, :published, seller:, shown_on_profile: true) }

        data = Pages::ProfileData.build(seller.reload)

        expect(data[:posts].length).to eq(2)
        expect(data[:posts_total]).to eq(3)
      end
    end

    context "when the catalogue is within MAX_ITEMS" do
      it "reports a total equal to the array length" do
        2.times { create(:product, user: seller) }

        data = Pages::ProfileData.build(seller.reload)

        expect(data[:products_total]).to eq(data[:products].length)
      end

      it "counts only payload-eligible products" do
        create(:product, user: seller)
        create(:product, user: seller, purchase_disabled_at: Time.current, deleted_at: Time.current)

        expect(Pages::ProfileData.build(seller.reload)[:products_total]).to eq(1)
      end
    end
  end

  describe ".products_page" do
    let(:seller) { create(:user) }

    it "returns the slice at the requested offset, in the full payload's order, with the total" do
      products = 5.times.map { |i| create(:product, user: seller, name: "Product #{i}", created_at: Time.utc(2026, 1, 1) + i.minutes) }

      page = Pages::ProfileData.products_page(seller.reload, offset: 2, limit: 2)

      expect(page[:products].pluck(:name)).to eq([products[2].name, products[1].name])
      expect(page[:products_total]).to eq(5)
    end

    it "continues exactly where the injected page 1 payload stopped" do
      stub_const("Pages::ProfileData::MAX_ITEMS", 2)
      3.times { |i| create(:product, user: seller, name: "Product #{i}", created_at: Time.utc(2026, 1, 1) + i.minutes) }

      page_one = Pages::ProfileData.build(seller.reload)[:products]
      page_two = Pages::ProfileData.products_page(seller.reload, offset: 2, limit: 2)

      expect(page_one.length).to eq(2)
      expect(page_two[:products].pluck(:name)).to eq(["Product 0"])
      expect((page_one + page_two[:products]).pluck(:url).uniq.length).to eq(3)
    end

    it "breaks created_at ties by id so adjacent slices never overlap or skip" do
      created_at = Time.utc(2026, 1, 1)
      6.times { |i| create(:product, user: seller, name: "Tied #{i}", created_at:) }

      slices = [0, 2, 4].map { |offset| Pages::ProfileData.products_page(seller.reload, offset:, limit: 2)[:products] }
      names = slices.flatten.pluck(:name)

      expect(names.length).to eq(6)
      expect(names.uniq.length).to eq(6)
    end

    it "caches each slice under the payload's cache version" do
      product = create(:product, user: seller, name: "Original name")
      first_read = Pages::ProfileData.products_page(seller.reload, offset: 0, limit: 1)
      expect(first_read[:products].first[:name]).to eq("Original name")

      # A write that skips callbacks leaves links.updated_at (the cache key's freshness source)
      # alone, so the slice is still served from cache…
      product.update_column(:name, "Renamed")
      expect(Pages::ProfileData.products_page(seller.reload, offset: 0, limit: 1)[:products].first[:name]).to eq("Original name")

      # …and a real save moves the key, busting it.
      product.touch
      expect(Pages::ProfileData.products_page(seller.reload, offset: 0, limit: 1)[:products].first[:name]).to eq("Renamed")
    end
  end
end
