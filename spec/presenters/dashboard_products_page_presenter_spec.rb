# frozen_string_literal: true

require "spec_helper"

describe DashboardProductsPagePresenter do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:presenter) { described_class.new(pundit_user:) }
  let(:start) { 1.hour.ago }

  def row_for(product)
    presenter.products_table_props[:products].find { _1["id"] == product.id }
  end

  describe "#products_table_props" do
    it "carries the play sessions and their average length for a product with a build" do
      product = create(:product, user: seller)
      build = create(:product_build, :live, product:)
      purchase = create(:purchase, link: product)
      long = ProductBuildPlaySession.start!(product_build: build, purchase:, at: start)
      long.update!(last_heartbeat_at: start + 6.minutes)
      short = ProductBuildPlaySession.start!(product_build: build, purchase:, at: start)
      short.update!(last_heartbeat_at: start + 2.minutes)

      expect(row_for(product)).to include("play_sessions_count" => 2, "average_play_session_seconds" => 4.minutes.to_i)
    end

    it "counts none for a product with a build nobody played" do
      product = create(:product, user: seller)
      create(:product_build, :live, product:)

      expect(row_for(product)).to include("play_sessions_count" => 0, "average_play_session_seconds" => nil)
    end

    it "leaves the keys off a product with no build" do
      product = create(:product, user: seller)

      expect(row_for(product)).not_to include("play_sessions_count", "average_play_session_seconds")
    end

    it "counts only the plays of the product's own builds" do
      product = create(:product, user: seller)
      create(:product_build, :live, product:)
      other_product = create(:product, user: seller)
      other_build = create(:product_build, :live, product: other_product)
      ProductBuildPlaySession.start!(product_build: other_build, purchase: create(:purchase, link: other_product), at: start)

      expect(row_for(product)).to include("play_sessions_count" => 0)
      expect(row_for(other_product)).to include("play_sessions_count" => 1)
    end
  end
end
