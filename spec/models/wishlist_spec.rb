# frozen_string_literal: true

require "spec_helper"

describe Wishlist do
  describe "#find_by_url_slug" do
    let(:wishlist) { create(:wishlist) }

    it "finds a wishlist" do
      expect(Wishlist.find_by_url_slug(wishlist.url_slug)).to eq(wishlist)
    end

    it "returns nil when the wishlist does not exist" do
      expect(Wishlist.find_by_url_slug("foo")).to be_nil
    end
  end

  describe "#url_slug" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist") }

    it "returns a readable URL path plus the ID" do
      expect(wishlist.url_slug).to eq("my-wishlist-#{wishlist.external_id_numeric}")
    end
  end

  describe "#followed_by?" do
    let(:wishlist) { create(:wishlist) }
    let(:user) { create(:user) }

    context "when the user is following the wishlist" do
      before do
        create(:wishlist_follower, wishlist: wishlist, follower_user: user)
      end

      it "returns true" do
        expect(wishlist.followed_by?(user)).to eq(true)
      end
    end

    context "when the user has unfollowed the wishlist" do
      before do
        create(:wishlist_follower, wishlist: wishlist, follower_user: user, deleted_at: Time.current)
      end

      it "returns false" do
        expect(wishlist.followed_by?(user)).to eq(false)
      end
    end

    context "when the user is not following the wishlist" do
      it "returns false" do
        expect(wishlist.followed_by?(user)).to eq(false)
      end
    end
  end

  describe "#wishlist_products_for_email" do
    let(:wishlist) { create(:wishlist) }
    let(:old_product) { create(:wishlist_product, wishlist: wishlist, created_at: 1.day.ago) }
    let(:new_product) { create(:wishlist_product, wishlist: wishlist, created_at: 1.hour.ago) }
    let(:deleted_product) { create(:wishlist_product, wishlist: wishlist, deleted_at: Time.current) }

    context "when no email has been sent yet" do
      it "returns alive products" do
        expect(wishlist.wishlist_products_for_email).to match_array([old_product, new_product])
      end
    end

    context "when an email has been sent" do
      before { wishlist.update!(followers_last_contacted_at: 12.hours.ago) }

      it "returns alive products added after the last email" do
        expect(wishlist.wishlist_products_for_email).to eq([new_product])
      end
    end
  end

  describe "SEO indexability" do
    let(:wishlist) { create(:wishlist, name: "Curated Things") }

    describe ".seo_indexable and #seo_indexable?" do
      it "includes only recommendable wishlists with at least the minimum products" do
        create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist:)

        thin_wishlist = create(:wishlist, name: "Thin List")
        create(:wishlist_product, wishlist: thin_wishlist)

        opted_out_wishlist = create(:wishlist, name: "Hidden List", discover_opted_out: true)
        create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist: opted_out_wishlist)

        default_name_wishlist = create(:wishlist)
        create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist: default_name_wishlist)

        expect(Wishlist.seo_indexable).to contain_exactly(wishlist)
        expect(wishlist.reload.seo_indexable?).to be true
        expect(thin_wishlist.reload.seo_indexable?).to be false
        expect(opted_out_wishlist.reload.seo_indexable?).to be false
        expect(default_name_wishlist.reload.seo_indexable?).to be false
      end

      it "counts distinct products, not wishlist_products rows" do
        # Same membership product wished twice (different recurrences) is two
        # alive rows but one product.
        membership = create(:membership_product_with_preset_tiered_pricing)
        create(:wishlist_product, wishlist:, product: membership, variant: membership.alive_variants.first, recurrence: "monthly")
        create(:wishlist_product, wishlist:, product: membership, variant: membership.alive_variants.first, recurrence: "yearly")
        create(:wishlist_product, wishlist:)

        expect(wishlist.alive_wishlist_products.count).to eq(3)
        expect(Wishlist.seo_indexable).to be_empty
        expect(wishlist.reload.seo_indexable?).to be false

        create(:wishlist_product, wishlist:)

        expect(Wishlist.seo_indexable).to contain_exactly(wishlist)
        expect(wishlist.reload.seo_indexable?).to be true
      end

      it "does not count deleted wishlist products toward the minimum" do
        create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist:)
        wishlist.wishlist_products.first.mark_deleted!

        expect(Wishlist.seo_indexable).to be_empty
        expect(wishlist.reload.seo_indexable?).to be false
      end
    end
  end

  describe "#structured_data" do
    let(:wishlist) { create(:wishlist, name: "Curated Things") }

    it "returns an ItemList with product name, url, and price" do
      products = create_list(:product, 3, price_cents: 1500)
      products.each { create(:wishlist_product, wishlist:, product: _1) }

      data = wishlist.structured_data

      expect(data["@type"]).to eq("ItemList")
      expect(data["name"]).to eq("Curated Things")
      expect(data["numberOfItems"]).to eq(3)
      expect(data["itemListElement"].map { _1["position"] }).to eq([1, 2, 3])
      expect(data["itemListElement"].first["item"]).to eq(
        "@type" => "Product",
        "name" => products.first.name,
        "url" => products.first.long_url,
        "offers" => {
          "@type" => "Offer",
          "price" => 15.0,
          "priceCurrency" => "USD",
          "url" => products.first.long_url
        }
      )
    end

    it "emits the native major-unit price for a zero-decimal currency" do
      product = create(:product, price_currency_type: "jpy", price_cents: 14_800)
      create(:wishlist_product, wishlist:, product:)

      offer = wishlist.structured_data["itemListElement"].first["item"]["offers"]

      expect(offer["price"]).to eq(14_800.0)
      expect(offer["priceCurrency"]).to eq("JPY")
    end

    it "returns an empty hash when there are no alive products" do
      create(:wishlist_product, wishlist:, deleted_at: Time.current)

      expect(wishlist.structured_data).to eq({})
    end
  end

  describe "#update_recommendable" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist") }

    before do
      create(:wishlist_product, wishlist:)
    end

    context "when there are alive wishlist products" do
      it "sets recommendable to true" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be true
      end
    end

    context "when there are no alive wishlist products" do
      before { wishlist.wishlist_products.each(&:mark_deleted!) }

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when name is adult" do
      before do
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.name).and_return(true)
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.description).and_return(false)
      end

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when description is adult" do
      before do
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.name).and_return(false)
        allow(AdultKeywordDetector).to receive(:adult?).with(wishlist.description).and_return(true)
      end

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when discover is opted out" do
      before { wishlist.discover_opted_out = true }

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when name is a default auto-generated one" do
      before { wishlist.name = "Wishlist 1" }

      it "sets recommendable to false" do
        wishlist.update_recommendable
        expect(wishlist.recommendable).to be false
      end
    end

    context "when save is true" do
      before { wishlist.discover_opted_out = true }

      it "saves the record" do
        wishlist.update_recommendable(save: true)
        expect(wishlist.reload.recommendable).to be false
      end
    end

    context "when save is false" do
      before { wishlist.discover_opted_out = true }

      it "does not save the record" do
        wishlist.update_recommendable(save: false)
        expect(wishlist.recommendable).to be false
        expect(wishlist.reload.recommendable).to be true
      end
    end
  end
end
