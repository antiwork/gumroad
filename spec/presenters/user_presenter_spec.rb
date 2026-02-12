# frozen_string_literal: true

require "spec_helper"

describe UserPresenter do
  let(:seller) { create(:named_seller) }
  let(:presenter) { described_class.new(user: seller) }

  describe "#audience_count" do
    it "returns audience_members count" do
      create_list(:audience_member, 3, seller:)
      expect(presenter.audience_count).to eq(3)
    end
  end

  describe "#audience_types" do
    it "returns array with matching classes to audience stats" do
      expect(presenter.audience_types).to be_empty
      create(:audience_member, seller:, purchases: [{}])
      expect(presenter.audience_types).to eq([:customers])
      create(:audience_member, seller:, follower: {})
      expect(presenter.audience_types).to eq([:customers, :followers])
      create(:audience_member, seller:, affiliates: [{}])
      expect(presenter.audience_types).to eq([:customers, :followers, :affiliates])
    end
  end

  describe "#products_for_filter_box" do
    let!(:product) { create(:product, user: seller) }
    let!(:deleted_product) { create(:product, user: seller, name: "Deleted", deleted_at: Time.current) }
    let!(:archived_product) { create(:product, user: seller, name: "Archived", archived: true) }
    let!(:archived_product_with_sales) { create(:product, user: seller, name: "Archived with sales", archived: true) }

    before do
      create(:purchase, link: archived_product_with_sales)
      index_model_records(Purchase)
    end

    it "returns correct products" do
      expect(presenter.products_for_filter_box).to eq([product, archived_product_with_sales])
    end
  end

  describe "#affiliate_products_for_filter_box" do
    let!(:product) { create(:product, user: seller) }
    let!(:deleted_product) { create(:product, user: seller, name: "Deleted", deleted_at: Time.current) }
    let!(:archived_product) { create(:product, user: seller, name: "Archived", archived: true) }
    let!(:archived_product_with_sales) { create(:product, user: seller, name: "Archived with sales", archived: true) }

    before do
      create(:purchase, link: archived_product_with_sales)
      index_model_records(Purchase)
    end

    it "returns correct products" do
      expect(presenter.products_for_filter_box).to eq([product, archived_product_with_sales])
    end
  end

  describe "#as_current_seller" do
    it "returns the correct props" do
      time_zone = ActiveSupport::TimeZone[seller.timezone]

      expect(presenter.as_current_seller).to eq(
        id: seller.external_id,
        email: seller.email,
        name: seller.display_name(prefer_email_over_default_username: true),
        subdomain: seller.subdomain,
        avatar_url: seller.avatar_url,
        is_buyer: seller.is_buyer?,
        time_zone: { name: time_zone.tzinfo.name, offset: time_zone.tzinfo.utc_offset },
        has_published_products: seller.products.alive.exists?,
        is_name_invalid_for_email_delivery: seller.is_name_invalid_for_email_delivery?,
        profile_background_color: seller.seller_profile.background_color,
        profile_highlight_color: seller.seller_profile.highlight_color,
        profile_font: seller.seller_profile.font
      )
    end
  end

  describe "#author_byline_props" do
    it "returns the correct props" do
      expect(presenter.author_byline_props).to eq(
        id: seller.external_id,
        name: seller.name,
        avatar_url: seller.avatar_url,
        profile_url: seller.profile_url(recommended_by: nil)
      )
    end

    context "when given a custom domain" do
      it "uses the custom domain for the profile url" do
        expect(presenter.author_byline_props(custom_domain_url: "https://example.com")[:profile_url]).to eq("https://example.com")
      end
    end

    context "when the seller does not have a name" do
      before { seller.update!(name: nil) }

      it "returns the username" do
        expect(presenter.author_byline_props(custom_domain_url: "https://example.com")[:name]).to eq(seller.username)
      end
    end

    context "when given recommended_by" do
      it "adds the parameter to the profile url" do
        expect(presenter.author_byline_props(recommended_by: "discover")[:profile_url]).to eq(seller.profile_url(recommended_by: "discover"))
      end
    end
  end
end
