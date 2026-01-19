# frozen_string_literal: true

require "rails_helper"

describe Products::RichContentAnalyticsController, type: :request do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:other_user) { create(:user) }
  let(:purchase) { create(:purchase, link: product, user: other_user) }

  let!(:page1) { create(:rich_content, entity: product, title: "Page 1", position: 0) }
  let!(:page2) { create(:rich_content, entity: product, title: "Page 2", position: 1) }

  before do
    create(:rich_content_page_view, rich_content: page1, product:, purchase:, viewed_at: 5.days.ago)
    create(:rich_content_page_view, rich_content: page1, product:, purchase:, viewed_at: 2.days.ago)
    create(:rich_content_page_view, rich_content: page2, product:, purchase:, viewed_at: 3.days.ago)
  end

  describe "GET /products/:product_id/rich_content_analytics" do
    context "when authenticated as seller" do
      before { login_as(seller) }

      it "returns page view statistics" do
        get product_rich_content_analytics_index_path(product.custom_permalink), as: :json

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json).to have_key("page_stats")
        expect(json).to have_key("total_views")
      end

      it "returns stats for all pages" do
        get product_rich_content_analytics_index_path(product.custom_permalink), as: :json

        json = JSON.parse(response.body)
        expect(json["page_stats"].length).to eq(2)
      end

      it "returns correct view counts" do
        get product_rich_content_analytics_index_path(product.custom_permalink), as: :json

        json = JSON.parse(response.body)
        page1_stat = json["page_stats"].find { |s| s["page_title"] == "Page 1" }
        page2_stat = json["page_stats"].find { |s| s["page_title"] == "Page 2" }

        expect(page1_stat["view_count"]).to eq(2)
        expect(page2_stat["view_count"]).to eq(1)
      end

      it "accepts date range parameters" do
        get product_rich_content_analytics_index_path(product.custom_permalink),
            params: {
              start_date: 4.days.ago.to_date.to_s,
              end_date: 1.day.ago.to_date.to_s
            },
            as: :json

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        page1_stat = json["page_stats"].find { |s| s["page_title"] == "Page 1" }
        expect(page1_stat["view_count"]).to eq(1)
      end

      it "defaults to last 30 days when dates not provided" do
        get product_rich_content_analytics_index_path(product.custom_permalink), as: :json

        expect(response).to have_http_status(:success)
      end

      it "handles invalid date formats gracefully" do
        get product_rich_content_analytics_index_path(product.custom_permalink),
            params: {
              start_date: "invalid",
              end_date: "invalid"
            },
            as: :json

        expect(response).to have_http_status(:success)
      end
    end

    context "when authenticated as different user" do
      before { login_as(other_user) }

      it "denies access" do
        get product_rich_content_analytics_index_path(product.custom_permalink), as: :json

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when not authenticated" do
      it "redirects to login" do
        get product_rich_content_analytics_index_path(product.custom_permalink), as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when product does not exist" do
      before { login_as(seller) }

      it "returns not found" do
        expect {
          get product_rich_content_analytics_index_path("nonexistent"), as: :json
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when product has no rich content" do
      let(:empty_product) { create(:product, user: seller) }

      before { login_as(seller) }

      it "returns empty stats" do
        get product_rich_content_analytics_index_path(empty_product.custom_permalink), as: :json

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json["page_stats"]).to eq([])
        expect(json["total_views"]).to eq({})
      end
    end
  end
end
