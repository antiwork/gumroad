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
