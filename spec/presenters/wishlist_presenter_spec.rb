# frozen_string_literal: true

require "spec_helper"

describe WishlistPresenter do
  include Rails.application.routes.url_helpers

  describe ".library_props" do
    let(:wishlist1) { create(:wishlist, name: "My Wishlist 1", user: create(:user, name: "Wishlist 1 User"), discover_opted_out: true) }
    let(:wishlist2) { create(:wishlist, name: "My Wishlist 2") }

    before do
      create(:wishlist_product, wishlist: wishlist1)
      create(:wishlist_product, wishlist: wishlist1)

      create(:wishlist_product, wishlist: wishlist2)
    end

    it "returns the correct props for creator" do
      expect(described_class.library_props(wishlists: Wishlist.all)).to eq(
        [
          {
            id: wishlist1.external_id,
            name: wishlist1.name,
            url: wishlist_url(wishlist1.url_slug, host: wishlist1.user.subdomain_with_protocol),
            product_count: 2,
            creator: nil,
            discover_opted_out: true,
          },
          {
            id: wishlist2.external_id,
            name: wishlist2.name,
            url: wishlist_url(wishlist2.url_slug, host: wishlist2.user.subdomain_with_protocol),
            product_count: 1,
            creator: nil,
            discover_opted_out: false,
          }
        ]
      )
    end

    it "returns the correct props for non-creator" do
      expect(described_class.library_props(wishlists: Wishlist.all, is_wishlist_creator: false)).to eq(
        [
          {
            id: wishlist1.external_id,
            name: wishlist1.name,
            url: wishlist_url(wishlist1.url_slug, host: wishlist1.user.subdomain_with_protocol),
            product_count: 2,
            creator: {
              name: wishlist1.user.name_or_username,
              profile_url: wishlist1.user.profile_url,
              avatar_url: wishlist1.user.avatar_url
            },
            discover_opted_out: nil,
          },
          {
            id: wishlist2.external_id,
            name: wishlist2.name,
            url: wishlist_url(wishlist2.url_slug, host: wishlist2.user.subdomain_with_protocol),
            product_count: 1,
            creator: {
              name: wishlist2.user.name_or_username,
              profile_url: wishlist2.user.profile_url,
              avatar_url: wishlist2.user.avatar_url
            },
            discover_opted_out: nil,
          }
        ]
      )
    end
  end

  describe ".cards_props" do
    let(:wishlist1) { create(:wishlist, name: "My Wishlist 1", user: create(:user, name: "Wishlist 1 User")) }
    let(:wishlist2) { create(:wishlist, name: "My Wishlist 2") }
    let(:pundit_user) { SellerContext.logged_out }

    before do
      create_list(:wishlist_follower, 2, wishlist: wishlist1)
    end

    it "returns the correct props" do
      expect(described_class.cards_props(wishlists: Wishlist.where(id: [wishlist1.id, wishlist2.id]), pundit_user:)).to eq(
        [
          described_class.new(wishlist: wishlist1).card_props(pundit_user:, following: false),
          described_class.new(wishlist: wishlist2).card_props(pundit_user:, following: false),
        ]
      )
    end

    context "when the user is following the wishlist" do
      let(:user) { create(:user) }
      let(:pundit_user) { SellerContext.new(user:, seller: user) }

      before do
        create(:wishlist_follower, wishlist: wishlist1, follower_user: user)
      end

      it "returns true for following" do
        expect(described_class.cards_props(wishlists: Wishlist.where(id: wishlist1.id), pundit_user:).sole[:following]).to eq(true)
      end
    end
  end

  describe "#listing_props" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist") }

    it "returns the correct props" do
      expect(described_class.new(wishlist: wishlist).listing_props).to eq(
        id: wishlist.external_id,
        name: wishlist.name
      )
    end

    context "when given a product" do
      let(:product) { create(:product) }

      it "returns whether the product is in the wishlist" do
        expect(described_class.new(wishlist:).listing_props(product:)).to eq(
          id: wishlist.external_id,
          name: wishlist.name,
          selections_in_wishlist: []
        )

        create(:wishlist_product, wishlist:, product:)
        wishlist.reload

        expect(described_class.new(wishlist:).listing_props(product:)).to eq(
          id: wishlist.external_id,
          name: wishlist.name,
          selections_in_wishlist: [{ variant_id: nil, recurrence: nil, rent: false, quantity: 1 }]
        )
      end

      it "ignores deleted wishlist products" do
        wishlist_product = create(:wishlist_product, wishlist:, product:)
        wishlist_product.mark_deleted!
        wishlist.reload

        expect(described_class.new(wishlist:).listing_props(product:)).to eq(
          id: wishlist.external_id,
          name: wishlist.name,
          selections_in_wishlist: []
        )
      end

      context "when the product has variants" do
        let(:product) { create(:membership_product_with_preset_tiered_pricing) }

        it "returns which variants are in the wishlist" do
          expect(described_class.new(wishlist:).listing_props(product:)).to eq(
            id: wishlist.external_id,
            name: wishlist.name,
            selections_in_wishlist: []
          )

          create(:wishlist_product, wishlist:, product:, variant: product.alive_variants.first, recurrence: BasePrice::Recurrence::MONTHLY)
          create(:wishlist_product, wishlist:, product:, variant: product.alive_variants.second, recurrence: BasePrice::Recurrence::MONTHLY)
          wishlist.reload

          expect(described_class.new(wishlist:).listing_props(product:)).to eq(
            id: wishlist.external_id,
            name: wishlist.name,
            selections_in_wishlist: [
              { variant_id: product.alive_variants.first.external_id, recurrence: BasePrice::Recurrence::MONTHLY, rent: false, quantity: 1 },
              { variant_id: product.alive_variants.second.external_id, recurrence: BasePrice::Recurrence::MONTHLY, rent: false, quantity: 1 }
            ]
          )
        end
      end
    end
  end

  describe "#public_props" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist", description: "I recommend these", user: create(:user, name: "Wishlister")) }
    let(:pundit_user) { SellerContext.new(user: wishlist.user, seller: wishlist.user) }

    before do
      create(:wishlist_product, :with_quantity, wishlist:)
      create(:wishlist_product, :with_recurring_variant, wishlist:)
    end

    it "returns the correct props" do
      expect(described_class.new(wishlist:).public_props(request: nil, pundit_user: nil)).to match(
        id: wishlist.external_id,
        name: wishlist.name,
        description: wishlist.description,
        url: Rails.application.routes.url_helpers.wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol),
        user: {
          name: "Wishlister",
          avatar_url: wishlist.user.avatar_url,
          profile_url: wishlist.user.profile_url,
        },
        following: false,
        can_follow: true,
        can_edit: false,
        checkout_enabled: true,
        discover_opted_out: nil,
        items: [
          {
            id: wishlist.wishlist_products.first.external_id,
            product: a_hash_including(
              id: wishlist.wishlist_products.first.product.external_id,
            ),
            purchasable: true,
            giftable: true,
            option: nil,
            quantity: 5,
            recurrence: nil,
            rent: false,
            created_at: wishlist.wishlist_products.first.created_at
          },
          {
            id: wishlist.wishlist_products.second.external_id,
            product: a_hash_including(
              id: wishlist.wishlist_products.second.product.external_id,
            ),
            purchasable: true,
            giftable: true,
            option: wishlist.wishlist_products.second.variant.to_option,
            quantity: 1,
            recurrence: "monthly",
            rent: false,
            created_at: wishlist.wishlist_products.second.created_at
          }
        ],
        pagination: {
          count: 2,
          items: 20,
          page: 1,
          pages: 1,
          prev: nil,
          next: nil,
          last: 1
        },
      )
    end

    context "for a pre-order product" do
      it "is not giftable" do
        wishlist.wishlist_products.first.product.update!(is_in_preorder_state: true)
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user: nil)[:items].first[:giftable]).to eq(false)
      end
    end

    context "for the user's own wishlist" do
      it "is not giftable" do
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user:)[:items]).to be_all { |item| item[:giftable] == false }
      end

      it "cannot be followed" do
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user:)[:can_follow]).to eq(false)
      end

      it "does not return user props" do
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user:)[:user]).to be_nil
      end
    end

    context "when no products are purchaseable" do
      before do
        wishlist.wishlist_products.each { |wishlist_product| wishlist_product.product.unpublish! }
      end

      it "disables checkout" do
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user:)[:checkout_enabled]).to eq(false)
      end
    end

    context "when the user is following the wishlist" do
      let(:user) { create(:user) }
      let(:pundit_user) { SellerContext.new(user:, seller: user) }

      before do
        create(:wishlist_follower, wishlist:, follower_user: user)
      end

      it "returns true for following" do
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user:)[:following]).to eq(true)
      end
    end

    context "when the follow feature flag is disabled" do
      before { Feature.deactivate(:follow_wishlists) }

      it "cannot be followed" do
        expect(described_class.new(wishlist:).public_props(request: nil, pundit_user:)[:can_follow]).to eq(false)
      end
    end
  end

  describe "#public_items" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist", user: create(:user, name: "Wishlister")) }
    let(:pundit_user) { SellerContext.logged_out }
    let(:request) { nil }

    it "returns items with pagination metadata" do
      create(:wishlist_product, :with_quantity, wishlist:)
      create(:wishlist_product, :with_recurring_variant, wishlist:)

      result = described_class.new(wishlist:).public_items(request:, pundit_user:)

      expect(result[:items].length).to eq(2)
      expect(result[:items].first).to include(
        :id, :product, :option, :recurrence, :quantity, :rent, :created_at, :purchasable, :giftable
      )
      expect(result[:pagination]).to include(
        count: 2,
        items: 20,
        page: 1,
        pages: 1
      )
    end

    it "paginates items correctly" do
      create_list(:wishlist_product, 25, wishlist:)

      first_page = described_class.new(wishlist:).public_items(request:, pundit_user:, page: 1)
      second_page = described_class.new(wishlist:).public_items(request:, pundit_user:, page: 2)

      expect(first_page[:items].length).to eq(20)
      expect(first_page[:pagination]).to include(page: 1, pages: 2, next: 2)

      expect(second_page[:items].length).to eq(5)
      expect(second_page[:pagination]).to include(page: 2, prev: 1, next: nil)
    end
  end

  describe "#card_props" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist", description: "I recommend these", user: create(:user, name: "Wishlister")) }
    let(:pundit_user) { SellerContext.logged_out }

    let!(:product_with_thumbnail) { create(:product) }

    before do
      create(:thumbnail, product: product_with_thumbnail)

      create(:wishlist_product, wishlist:)
      create(:wishlist_product, wishlist:, product: product_with_thumbnail)
      create(:wishlist_follower, wishlist:)
    end

    it "returns the correct props" do
      expect(described_class.new(wishlist:).card_props(pundit_user: nil, following: false)).to eq(
        id: wishlist.external_id,
        url: Rails.application.routes.url_helpers.wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol),
        name: wishlist.name,
        description: wishlist.description,
        seller: {
          id: wishlist.user.external_id,
          name: "Wishlister",
          avatar_url: wishlist.user.avatar_url,
          profile_url: wishlist.user.profile_url,
        },
        thumbnails: [
          { url: product_with_thumbnail.thumbnail_alive.url, native_type: "digital" },
        ],
        product_count: 2,
        follower_count: 1,
        following: false,
        can_follow: true,
      )
    end

    it "passes through the layout param to the url" do
      expect(described_class.new(wishlist:).card_props(pundit_user:, following: false, layout: Product::Layout::PROFILE)[:url]).to eq(
        Rails.application.routes.url_helpers.wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol, layout: Product::Layout::PROFILE)
      )
    end

    context "when there are 4 or more products" do
      before do
        create(:wishlist_product, wishlist:, product: create(:product))
        create(:wishlist_product, wishlist:, product: create(:product))
      end

      it "returns 4 thumbnails" do
        expect(described_class.new(wishlist:).card_props(pundit_user:, following: false)[:thumbnails]).to eq(
          [
            { url: nil, native_type: "digital" },
            { url: product_with_thumbnail.thumbnail_alive.url, native_type: "digital" },
            { url: nil, native_type: "digital" },
            { url: nil, native_type: "digital" },
          ]
        )
      end
    end

    context "thumbnails" do
      let!(:product_with_only_thumbnail) { create(:product) }
      let!(:product_with_only_cover) { create(:product) }
      let!(:product_with_neither_1) { create(:product) }
      let!(:product_with_neither_2) { create(:product) }

      let!(:thumbnail) { create(:thumbnail, product: product_with_only_thumbnail) }
      let!(:cover_image) { create(:asset_preview_jpg, link: product_with_only_cover) }

      let!(:wishlist_for_thumbnails) do
        create(
          :wishlist,
          wishlist_products: [
            build(:wishlist_product, product: product_with_only_thumbnail),
            build(:wishlist_product, product: product_with_only_cover),
            build(:wishlist_product, product: product_with_neither_1),
            build(:wishlist_product, product: product_with_neither_2),
          ],
        )
      end

      it "falls back to cover image url" do
        result = described_class.new(wishlist: wishlist_for_thumbnails)
          .card_props(pundit_user:, following: false)

        expect(result[:thumbnails]).to contain_exactly(
          { url: thumbnail.url, native_type: "digital" },
          { url: cover_image.url, native_type: "digital" },
          { url: nil, native_type: "digital" },
          { url: nil, native_type: "digital" },
        )
      end
    end

    context "for the user's own wishlist" do
      let(:pundit_user) { SellerContext.new(user: wishlist.user, seller: wishlist.user) }

      it "cannot be followed" do
        expect(described_class.new(wishlist:).card_props(pundit_user:, following: false)[:can_follow]).to eq(false)
      end
    end
  end
end
