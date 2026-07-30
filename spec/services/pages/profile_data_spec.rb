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

      before do
        allow(CustomDomainVerificationService)
          .to receive(:new)
          .with(domain: "shop.example.com")
          .and_return(double(domains_pointed_to_gumroad: ["shop.example.com"]))
      end

      it "builds product and post URLs on the custom domain, not the subdomain" do
        create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")

        payload = Pages::ProfileData.build(seller.reload)

        expect(payload[:products].first[:url]).to eq("#{PROTOCOL}://shop.example.com/l/#{product.general_permalink}")
        expect(payload[:posts].first[:url]).to start_with("#{PROTOCOL}://shop.example.com/p/")
        expect(payload.to_json).not_to include(seller.subdomain)
      end

      it "caches exact-host DNS verification across profile-data cache reads" do
        create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        expect(CustomDomainVerificationService)
          .to receive(:new)
          .with(domain: "shop.example.com")
          .once
          .and_return(double(domains_pointed_to_gumroad: ["shop.example.com"]))

        2.times { Pages::ProfileData.build(seller.reload) }
      end

      it "stays on the subdomain when only the configured domain's apex points to Gumroad" do
        create(:custom_domain, :verified_with_certificate, user: seller, domain: "www.example.com")
        allow(CustomDomainVerificationService)
          .to receive(:new)
          .with(domain: "www.example.com")
          .and_return(double(domains_pointed_to_gumroad: ["example.com"]))

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

        create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include("shop.example.com")
      end

      it "moves the URLs back to the subdomain when the domain is removed" do
        custom_domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include("shop.example.com")

        custom_domain.mark_deleted!

        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include(seller.subdomain)
      end

      it "keeps the emitted host inside the navigation bridge's allowlist" do
        create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
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

      it "leaves the custom-domain host behind when the certificate ages out with no DB write" do
        domain = create(:custom_domain, :verified_with_certificate, user: seller, domain: "shop.example.com")
        expect(Pages::ProfileData.build(seller.reload)[:products].first[:url]).to include("shop.example.com")

        # active? goes false purely by the clock, so the domain row's updated_at never moves.
        domain.update_columns(ssl_certificate_issued_at: 8.days.ago)

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

    it "does not serve a v4 payload without the totals" do
      seller_profile = SellerProfile.find_by(seller_id: seller.id)
      current_key = Pages::ProfileData.cache_key(seller, seller_profile)
      v4_key = current_key.sub("profile_data/v5/", "profile_data/v4/")
      Rails.cache.write(v4_key, { products: [], posts: [], pages: [] })

      data = Pages::ProfileData.build(seller)

      expect(current_key).to start_with("profile_data/v5/")
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
end
