# frozen_string_literal: true

require "rails_helper"

describe CreatorAnalytics::RichContentPageViews do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }
  let(:purchase) { create(:purchase, link: product, user:) }
  let(:start_date) { 30.days.ago.to_date }
  let(:end_date) { Date.current }

  let!(:page1) { create(:rich_content, entity: product, title: "Introduction", position: 0) }
  let!(:page2) { create(:rich_content, entity: product, title: "Chapter 1", position: 1) }
  let!(:page3) { create(:rich_content, entity: product, title: "Chapter 2", position: 2) }

  let(:service) do
    described_class.new(
      product:,
      start_date:,
      end_date:
    )
  end

  before do
    create(:rich_content_page_view, rich_content: page1, product:, purchase:, viewed_at: 5.days.ago)
    create(:rich_content_page_view, rich_content: page1, product:, purchase:, viewed_at: 3.days.ago)
    create(:rich_content_page_view, rich_content: page1, product:, purchase:, viewed_at: 1.day.ago)
    create(:rich_content_page_view, rich_content: page2, product:, purchase:, viewed_at: 2.days.ago)
    create(:rich_content_page_view, rich_content: page2, product:, purchase:, viewed_at: 1.day.ago)
  end

  describe "#page_view_stats" do
    it "returns stats for all pages" do
      stats = service.page_view_stats
      expect(stats.length).to eq(3)
    end

    it "returns pages in position order" do
      stats = service.page_view_stats
      expect(stats.map { |s| s[:page_title] }).to eq(["Introduction", "Chapter 1", "Chapter 2"])
    end

    it "returns correct view counts" do
      stats = service.page_view_stats
      intro_stat = stats.find { |s| s[:page_title] == "Introduction" }
      chapter1_stat = stats.find { |s| s[:page_title] == "Chapter 1" }
      chapter2_stat = stats.find { |s| s[:page_title] == "Chapter 2" }

      expect(intro_stat[:view_count]).to eq(3)
      expect(chapter1_stat[:view_count]).to eq(2)
      expect(chapter2_stat[:view_count]).to eq(0)
    end

    it "includes page external IDs" do
      stats = service.page_view_stats
      expect(stats.first[:page_id]).to eq(page1.external_id)
    end

    it "handles untitled pages" do
      untitled_page = create(:rich_content, entity: product, title: nil, position: 3)
      create(:rich_content_page_view, rich_content: untitled_page, product:, purchase:)

      stats = service.page_view_stats
      untitled_stat = stats.last
      expect(untitled_stat[:page_title]).to eq("Untitled")
    end

    it "returns empty array when product has no rich content" do
      product_without_content = create(:product)
      service = described_class.new(product: product_without_content, start_date:, end_date:)

      expect(service.page_view_stats).to eq([])
    end

    it "filters by date range" do
      recent_start = 2.days.ago.to_date
      recent_end = Date.current
      recent_service = described_class.new(product:, start_date: recent_start, end_date: recent_end)

      stats = recent_service.page_view_stats
      intro_stat = stats.find { |s| s[:page_title] == "Introduction" }
      expect(intro_stat[:view_count]).to eq(2)
    end
  end

  describe "#page_views_over_time" do
    it "returns view counts grouped by page and date" do
      result = service.page_views_over_time
      expect(result).to be_a(Hash)
      expect(result.keys.first).to include(:page_id, :page_title, :date)
    end

    it "returns correct counts per day" do
      result = service.page_views_over_time
      page1_views = result.select { |key, _| key[:page_id] == page1.external_id }
      expect(page1_views.values.sum).to eq(3)
    end

    it "returns empty hash when product has no rich content" do
      product_without_content = create(:product)
      service = described_class.new(product: product_without_content, start_date:, end_date:)

      expect(service.page_views_over_time).to eq({})
    end
  end

  describe "#total_views_by_page" do
    it "returns hash with external IDs as keys" do
      result = service.total_views_by_page
      expect(result).to be_a(Hash)
      expect(result.keys).to include(page1.external_id, page2.external_id)
    end

    it "returns correct total counts" do
      result = service.total_views_by_page
      expect(result[page1.external_id]).to eq(3)
      expect(result[page2.external_id]).to eq(2)
    end

    it "does not include pages with zero views" do
      result = service.total_views_by_page
      expect(result[page3.external_id]).to be_nil
    end

    it "returns empty hash when product has no rich content" do
      product_without_content = create(:product)
      service = described_class.new(product: product_without_content, start_date:, end_date:)

      expect(service.total_views_by_page).to eq({})
    end
  end
end
