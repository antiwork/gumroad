# frozen_string_literal: true

require "spec_helper"

describe PaginatedUtmLinksPresenter do
  let(:seller) { create(:named_seller) }
  let!(:utm_link1) { create(:utm_link, seller:, created_at: 1.day.ago, unique_clicks: 3) }
  let!(:utm_link2) { create(:utm_link, seller:, created_at: 3.days.ago, unique_clicks: 1) }
  let!(:utm_link3) { create(:utm_link, seller:, created_at: 2.days.ago, unique_clicks: 0) }
  let(:product) { create(:product, user: seller) }
  let(:purchase1) { create(:purchase, price_cents: 1000, seller:, link: product) }
  let(:purchase2) { create(:purchase, price_cents: 2000, seller:, link: product) }
  let(:purchase3) { create(:purchase, price_cents: 500, seller:, link: product) }
  let(:test_purchase) { create(:test_purchase, price_cents: 3000, seller:, link: product) }
  let(:failed_purchase) { create(:failed_purchase, price_cents: 1000, seller:, link: product) }
  let!(:utm_link1_driven_sale1) { create(:utm_link_driven_sale, utm_link: utm_link1, purchase: purchase1) }
  let!(:utm_link1_driven_sale2) { create(:utm_link_driven_sale, utm_link: utm_link1, purchase: purchase2) }
  let!(:utm_link2_driven_sale1) { create(:utm_link_driven_sale, utm_link: utm_link2, purchase: purchase3) }
  let!(:utm_link2_driven_sale2) { create(:utm_link_driven_sale, utm_link: utm_link2, purchase: test_purchase) }
  let!(:utm_link2_driven_sale3) { create(:utm_link_driven_sale, utm_link: utm_link2, purchase: failed_purchase) }

  describe "#props" do
    it "returns the paginated UTM links props" do
      stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 2)

      props = described_class.new(seller:).props
      expect(props).to match(PaginatedUtmLinksPresenter.new(seller:).props)
      expect(props[:utm_links]).to match_array([
                                                 UtmLinkPresenter.new(seller:, utm_link: utm_link1).utm_link_props,
                                                 UtmLinkPresenter.new(seller:, utm_link: utm_link3).utm_link_props,
                                               ])
      expect(props[:utm_links].map { [_1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }).to match_array([[nil, nil, nil], [nil, nil, nil]])
      expect(props[:pagination]).to eq(pages: 2, page: 1)

      props = described_class.new(seller:, page: 2).props
      expect(props).to match(PaginatedUtmLinksPresenter.new(seller:, page: 2).props)
      expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link2).utm_link_props])
      expect(props[:utm_links].map { [_1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }).to match_array([[nil, nil, nil]])
      expect(props[:pagination]).to eq(pages: 2, page: 2)

      # When the page is greater than the number of pages, it returns the last page
      expect do
        props = described_class.new(seller:, page: 3).props
        expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link2).utm_link_props])
        expect(props[:pagination]).to eq(pages: 2, page: 2)
      end.not_to raise_error
    end

    it "sorts by date by default" do
      props = described_class.new(seller:).props
      expect(props[:utm_links].map { _1[:id] }).to eq([
                                                        utm_link1.external_id,
                                                        utm_link3.external_id,
                                                        utm_link2.external_id
                                                      ])
    end

    describe "sorting" do
      it "sorts by different columns" do
        utm_link1.update!(title: "C Link", utm_source: "facebook", utm_medium: "social", utm_campaign: "spring", unique_clicks: 10)
        utm_link2.update!(title: "A Link", utm_source: "twitter", utm_medium: "paid", utm_campaign: "winter", unique_clicks: 30)
        utm_link3.update!(title: "B Link", utm_source: "google", utm_medium: "organic", utm_campaign: "summer", unique_clicks: 20)

        sort_key_to_response_key_map = {
          "link" => :title,
          "date" => :created_at,
          "source" => :source,
          "medium" => :medium,
          "campaign" => :campaign,
          "clicks" => :clicks,
          "sales_count" => :sales_count,
          "revenue_cents" => :revenue_cents,
          "conversion_rate" => :conversion_rate,
        }
        sort_key_to_response_key_map.each do |key, column|
          ascending = described_class.new(seller:, sort: { key:, direction: "asc" }).props
          expect(ascending[:utm_links].map { _1[column] }).to eq(ascending[:utm_links].map { _1[column] }.sort)

          descending = described_class.new(seller:, sort: { key:, direction: "desc" }).props
          expect(descending[:utm_links].map { _1[column] }).to eq(descending[:utm_links].map { _1[column] }.sort.reverse)
        end
      end

      context "when sorted by sales_count, revenue_cents, or conversion_rate columns" do
        it "returns values for stats" do
          props = described_class.new(seller:, sort: { key: "sales_count", direction: "asc" }).props
          stats = props[:utm_links].map { [_1[:id], _1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [utm_link3.external_id, 0, 0, 0.0],
                                [utm_link2.external_id, 1, 500, 1.0],
                                [utm_link1.external_id, 2, 3000, 0.6667],
                              ])

          props = described_class.new(seller:, sort: { key: "sales_count", direction: "desc" }).props
          stats = props[:utm_links].map { [_1[:id], _1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [utm_link1.external_id, 2, 3000, 0.6667],
                                [utm_link2.external_id, 1, 500, 1.0],
                                [utm_link3.external_id, 0, 0, 0.0],
                              ])

          props = described_class.new(seller:, sort: { key: "revenue_cents", direction: "asc" }).props
          stats = props[:utm_links].map { [_1[:id], _1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [utm_link3.external_id, 0, 0, 0.0],
                                [utm_link2.external_id, 1, 500, 1.0],
                                [utm_link1.external_id, 2, 3000, 0.6667],
                              ])

          props = described_class.new(seller:, sort: { key: "revenue_cents", direction: "desc" }).props
          stats = props[:utm_links].map { [_1[:id], _1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [utm_link1.external_id, 2, 3000, 0.6667],
                                [utm_link2.external_id, 1, 500, 1.0],
                                [utm_link3.external_id, 0, 0, 0.0],
                              ])

          props = described_class.new(seller:, sort: { key: "conversion_rate", direction: "asc" }).props
          stats = props[:utm_links].map { [_1[:id], _1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [utm_link3.external_id, 0, 0, 0.0],
                                [utm_link1.external_id, 2, 3000, 0.6667],
                                [utm_link2.external_id, 1, 500, 1.0],
                              ])

          props = described_class.new(seller:, sort: { key: "conversion_rate", direction: "desc" }).props
          stats = props[:utm_links].map { [_1[:id], _1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [utm_link2.external_id, 1, 500, 1.0],
                                [utm_link1.external_id, 2, 3000, 0.6667],
                                [utm_link3.external_id, 0, 0, 0.0],
                              ])
        end
      end

      context "when sorted by any other column" do
        it "returns nil values for stats" do
          props = described_class.new(seller:, sort: { key: "link", direction: "asc" }).props
          stats = props[:utm_links].map { [_1[:sales_count], _1[:revenue_cents], _1[:conversion_rate]] }
          expect(stats).to eq([
                                [nil, nil, nil],
                                [nil, nil, nil],
                                [nil, nil, nil],
                              ])
        end
      end
    end

    it "filters UTM links by search query" do
      utm_link1.update!(
        title: "Facebook Summer Sale",
        utm_source: "facebook",
        utm_medium: "social",
        utm_campaign: "summer_2024",
        utm_term: "discount",
        utm_content: "banner_ad"
      )
      utm_link2.update!(
        title: "Twitter Winter Promo",
        utm_source: "twitter",
        utm_medium: "social",
        utm_campaign: "winter_2024",
        utm_term: "sale",
        utm_content: "post"
      )
      utm_link3.update!(
        title: "Google Summer Sale",
        utm_source: "google",
        utm_medium: "organic",
        utm_campaign: "summer_2024",
        utm_term: "discount",
        utm_content: "video_ad"
      )

      # Search by title
      props = described_class.new(seller:, query: "SuMMer", sort: { key: "link", direction: "desc" }).props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link3.external_id, utm_link1.external_id])

      # Search by source
      props = described_class.new(seller:, query: "twitter").props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link2.external_id])

      # Search by medium
      props = described_class.new(seller:, query: "social").props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id])

      # Search by campaign
      props = described_class.new(seller:, query: "winter").props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link2.external_id])

      # Search by term
      props = described_class.new(seller:, query: "discount").props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link3.external_id])

      # Search by content
      props = described_class.new(seller:, query: "video").props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link3.external_id])

      # Search with no matches
      props = described_class.new(seller:, query: "nonexistent").props
      expect(props[:utm_links]).to be_empty

      # Search with whitespace
      props = described_class.new(seller:, query: "     ").props
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id, utm_link3.external_id])
    end
  end
end
