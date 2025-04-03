# frozen_string_literal: true

require "spec_helper"

describe Discover::AutocompletePresenter do
  let(:user) { create(:user) }
  let(:browser_guid) { SecureRandom.uuid }
  let(:query) { "test" }
  let(:presenter) { described_class.new(query:, user:, browser_guid:) }

  let!(:product) { create(:product, :recommendable, name: "Test Product") }

  before do
    Link.import(force: true, refresh: true)
  end

  describe "#props" do
    context "when query is blank" do
      let(:query) { "" }

      let!(:product2) { create(:product, :recommendable, name: "Another Test Product") }
      let!(:product3) { create(:product, :recommendable, name: "Yet Another Test Product") }

      before do
        Link.import(force: true, refresh: true)
      end

      it "returns top products and recent searches" do
        create(:discover_search_suggestion, discover_search: create(:discover_search, user:, browser_guid:, query: "test", created_at: 1.day.ago))
        create_list(:discover_search_suggestion, 3, discover_search: create(:discover_search, user:, browser_guid:, query: "recent search"))
        result = presenter.props

        expect(result[:products]).to contain_exactly(
          {
            name: "Test Product",
            url: a_string_matching(/\/#{product.unique_permalink}\?autocomplete=true&layout=discover&recommended_by=search/),
            seller_name: "gumbo",
            thumbnail_url: nil,
          },
          {
            name: "Another Test Product",
            url: a_string_matching(/\/#{product2.unique_permalink}\?autocomplete=true&layout=discover&recommended_by=search/),
            seller_name: "gumbo",
            thumbnail_url: nil,
          },
          {
            name: "Yet Another Test Product",
            url: a_string_matching(/\/#{product3.unique_permalink}\?autocomplete=true&layout=discover&recommended_by=search/),
            seller_name: "gumbo",
            thumbnail_url: nil,
          },
        )
        expect(result[:viewed]).to be(false)
        expect(result[:recent_searches]).to eq(["recent search", "test"])
      end

      context "when the user has viewed products" do
        before do
          add_page_view(product, Time.current, user_id: user.id)
          ProductPageView.__elasticsearch__.refresh_index!
        end

        it "returns recently viewed products" do
          result = presenter.props

          expect(result[:products]).to contain_exactly(
            {
              name: "Test Product",
              url: a_string_matching(/\/#{product.unique_permalink}\?autocomplete=true&layout=discover&recommended_by=search/),
              seller_name: "gumbo",
              thumbnail_url: nil,
            },
          )
          expect(result[:viewed]).to be(true)
        end
      end

      context "when not logged in but has viewed products in this browser" do
        before do
          add_page_view(product2, Time.current, browser_guid:)
          ProductPageView.__elasticsearch__.refresh_index!
        end

        it "returns recently viewed products" do
          result = described_class.new(query:, user: nil, browser_guid:).props

          expect(result[:products]).to contain_exactly(
            {
              name: "Another Test Product",
              url: a_string_matching(/\/#{product2.unique_permalink}\?autocomplete=true&layout=discover&recommended_by=search/),
              seller_name: "gumbo",
              thumbnail_url: nil,
            },
          )
          expect(result[:viewed]).to be(true)
        end
      end
    end

    context "when query is present" do
      let(:query) { "test" }
      let!(:searches) do
        [
          create(:discover_search_suggestion, discover_search: create(:discover_search, user:, browser_guid:, query: "test query", created_at: 1.day.ago)),
          create(:discover_search_suggestion, discover_search: create(:discover_search, user:, browser_guid:, query: "another test", created_at: 1.hour.ago)),
          create(:discover_search_suggestion, discover_search: create(:discover_search, user:, browser_guid:, query: "unrelated", created_at: 1.minute.ago)),
        ]
      end

      it "returns matching products and filtered recent searches" do
        result = presenter.props

        expect(result[:products].sole).to match(
          name: "Test Product",
          url: a_string_matching(/\/#{product.unique_permalink}\?autocomplete=true&layout=discover&query=test&recommended_by=search/),
          seller_name: "gumbo",
          thumbnail_url: nil,
        )
        expect(result[:recent_searches]).to eq(["another test", "test query"])
      end
    end

    context "when user is nil" do
      let(:user) { nil }
      let!(:thumbnail) { create(:thumbnail, product:) }

      it "returns matching products" do
        expect(presenter.props[:products].sole).to match(
          name: "Test Product",
          url: a_string_matching(/\/#{product.unique_permalink}\?autocomplete=true&layout=discover&query=test&recommended_by=search/),
          seller_name: "gumbo",
          thumbnail_url: thumbnail.url,
        )
      end

      it "does not return recent searches" do
        create(:discover_search_suggestion, discover_search: create(:discover_search, user: nil, browser_guid:, query: "recent search"))
        expect(described_class.new(query:, user: nil, browser_guid:).props[:recent_searches]).to eq([])
      end
    end

    it "finds searches by user when user is present" do
      create(:discover_search_suggestion, discover_search: create(:discover_search, user:, browser_guid:, query: "user search"))
      create(:discover_search_suggestion, discover_search: create(:discover_search, user: nil, browser_guid:, query: "browser search"))
      result = described_class.new(query: "", user:, browser_guid: nil).props

      expect(result[:recent_searches]).to eq(["user search"])
    end

    it "finds searches by browser_guid when user is nil" do
      other_guid = SecureRandom.uuid
      create(:discover_search_suggestion, discover_search: create(:discover_search, user: nil, browser_guid:, query: "browser search"))
      create(:discover_search_suggestion, discover_search: create(:discover_search, user: nil, browser_guid: other_guid, query: "other search"))
      result = described_class.new(query: "", user: nil, browser_guid:).props

      expect(result[:recent_searches]).to eq(["browser search"])
    end
  end
end
