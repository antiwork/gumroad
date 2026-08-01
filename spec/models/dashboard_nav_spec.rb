# frozen_string_literal: true

require "spec_helper"

describe DashboardNav do
  describe "item keys" do
    # The client nav hardcodes the same keys. Drift is silent in both directions: a key only the
    # client knows renders a row that can never leave the overflow, because promoted_nav_items=
    # intersects with PROMOTABLE_ITEMS and discards it; a key only Ruby knows gets promoted and
    # never rendered.
    it "match the keys the client nav renders" do
      source = Rails.root.join("app/javascript/components/client-components/Nav/index.tsx").read
      client_keys = source.scan(/^\s+key: "([a-z_]+)",$/).flatten
      client_core = source[/^const CORE_ITEMS = \[(.*?)\];$/m, 1].to_s.scan(/"([a-z_]+)"/).flatten

      expect(client_keys.sort).to eq described_class::ITEMS.sort
      expect(client_core).to eq described_class::CORE_ITEMS
    end
  end

  describe ".item_for_path" do
    it "maps promotable dashboard paths to their item" do
      expect(described_class.item_for_path("/workflows")).to eq "workflows"
      expect(described_class.item_for_path("/workflows/123/emails")).to eq "workflows"
      expect(described_class.item_for_path("/emails")).to eq "emails"
      expect(described_class.item_for_path("/followers")).to eq "emails"
      expect(described_class.item_for_path("/communities")).to eq "community"
      expect(described_class.item_for_path("/wishlists")).to eq "library"
    end

    it "prefers the longest matching prefix" do
      expect(described_class.item_for_path("/dashboard/sales")).to eq "analytics"
      expect(described_class.item_for_path("/dashboard/audience")).to eq "analytics"
      expect(described_class.item_for_path("/dashboard/churn")).to eq "analytics"
    end

    it "ignores trailing slashes and casing" do
      expect(described_class.item_for_path("/Workflows/")).to eq "workflows"
    end

    it "returns nil for core and unrecognized paths" do
      expect(described_class.item_for_path("/dashboard")).to be_nil
      expect(described_class.item_for_path("/products")).to be_nil
      expect(described_class.item_for_path("/settings/main")).to be_nil
      expect(described_class.item_for_path("")).to be_nil
      expect(described_class.item_for_path(nil)).to be_nil
    end

    it "maps only the seller's checkout tabs, never the buyer's cart" do
      expect(described_class.item_for_path("/checkout/discounts")).to eq "checkout"
      expect(described_class.item_for_path("/checkout/form")).to eq "checkout"
      expect(described_class.item_for_path("/checkout/upsells")).to eq "checkout"

      # /checkout is the buyer cart and /checkout/returns/:id the buyer's return status; neither
      # renders the dashboard nav, and crediting them would earn the seller-side row for buyers.
      expect(described_class.item_for_path("/checkout")).to be_nil
      expect(described_class.item_for_path("/checkout/returns/123")).to be_nil
      expect(described_class.dashboard_path?("/checkout")).to be false
    end

    it "does not match a path that merely starts with an item's name" do
      expect(described_class.item_for_path("/pages-archive")).to be_nil
      expect(described_class.item_for_path("/libraryish")).to be_nil
    end

    it "only returns keys the nav can actually promote" do
      described_class::PATH_PREFIXES.each_value do |item|
        expect(described_class::PROMOTABLE_ITEMS).to include(item)
      end
    end
  end

  describe ".dashboard_path?" do
    it "recognizes core and promotable dashboard surfaces" do
      expect(described_class.dashboard_path?("/dashboard")).to be true
      expect(described_class.dashboard_path?("/products/abc/edit")).to be true
      expect(described_class.dashboard_path?("/payouts")).to be true
      expect(described_class.dashboard_path?("/workflows")).to be true
      expect(described_class.dashboard_path?("/discover")).to be true
    end

    it "recognizes every core surface, since dropping one silently stops seeding there" do
      # /customers is the Sales page and /settings the pinned footer destination — both render the
      # nav for sellers who may never touch a promotable path.
      expect(described_class::CORE_PATH_PREFIXES).to match_array %w[/dashboard /products /bundles /customers /payouts /settings /discover /help]
      described_class::CORE_PATH_PREFIXES.each do |prefix|
        expect(described_class.dashboard_path?(prefix)).to be true
        expect(described_class.item_for_path(prefix)).to be_nil
      end
    end

    it "rejects paths that do not render the dashboard nav" do
      expect(described_class.dashboard_path?("/l/some-product")).to be false
      expect(described_class.dashboard_path?("/checkout-abandoned")).to be false
      expect(described_class.dashboard_path?("/")).to be false
      expect(described_class.dashboard_path?(nil)).to be false
    end
  end

  describe ".earned_items" do
    let(:seller) { create(:user) }

    it "is empty for a brand new seller" do
      expect(described_class.earned_items(user: seller, seller:)).to eq []
    end

    it "credits a destination the seller's store already uses" do
      create(:product, user: seller)

      expect(described_class.earned_items(user: seller, seller:)).to include "profile"
    end

    it "credits analytics once the seller has a sale" do
      create(:purchase, seller:, link: create(:product, user: seller, price_cents: 0))

      items = described_class.earned_items(user: seller, seller:)
      expect(items).to include "analytics"
    end

    it "credits the buyer-side library from the browsing user, not the seller" do
      buyer = create(:user)
      create(:purchase, purchaser: buyer, seller:, link: create(:product, user: seller, price_cents: 0))

      expect(described_class.earned_items(user: buyer, seller:)).to include "library"
      expect(described_class.earned_items(user: seller, seller:)).not_to include "library"
    end

    it "ignores a deleted affiliate" do
      affiliate = create(:direct_affiliate, seller:)
      affiliate.mark_deleted!

      expect(described_class.earned_items(user: seller, seller:)).not_to include "affiliates"
    end

    it "credits affiliates from a pending request, before anyone is accepted" do
      create(:affiliate_request, seller:)

      expect(described_class.earned_items(user: seller, seller:)).to include "affiliates"
    end

    it "credits checkout from a custom field, with no discount or upsell" do
      create(:custom_field, seller:)

      expect(described_class.earned_items(user: seller, seller:)).to include "checkout"
    end

    it "credits emails from a follower list, before anything is sent" do
      create(:active_follower, user: seller)

      expect(described_class.earned_items(user: seller, seller:)).to include "emails"
    end

    it "credits community from a live community" do
      create(:community, seller:)

      expect(described_class.earned_items(user: seller, seller:)).to include "community"
    end

    it "credits pages from a page" do
      seller.pages.create!(title: "About", slug: "about-#{SecureRandom.hex(4)}")

      expect(described_class.earned_items(user: seller, seller:)).to include "pages"
    end

    it "returns only promotable keys" do
      create(:product, user: seller)
      create(:workflow, seller:)

      expect(described_class::PROMOTABLE_ITEMS).to include(*described_class.earned_items(user: seller, seller:))
    end

    it "is empty without a seller" do
      expect(described_class.earned_items(user: seller, seller: nil)).to eq []
    end
  end
end
