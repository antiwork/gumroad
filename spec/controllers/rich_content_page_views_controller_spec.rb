# frozen_string_literal: true

require "rails_helper"

describe RichContentPageViewsController, type: :request do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }
  let(:purchase) { create(:purchase, link: product, user:) }
  let(:url_redirect) { create(:url_redirect, purchase:) }
  let(:rich_content) { create(:rich_content, entity: product) }

  describe "POST /rich_content_page_views" do
    let(:valid_params) do
      {
        page_id: rich_content.external_id,
        url_redirect_id: url_redirect.id
      }
    end

    it "creates a new page view record" do
      expect {
        post rich_content_page_views_path, params: valid_params
      }.to change(RichContentPageView, :count).by(1)

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)["success"]).to be true
    end

    it "stores the correct attributes" do
      post rich_content_page_views_path, params: valid_params

      view = RichContentPageView.last
      expect(view.rich_content_id).to eq(rich_content.id)
      expect(view.purchase_id).to eq(purchase.id)
      expect(view.product_id).to eq(product.id)
      expect(view.buyer_id).to eq(user.id)
      expect(view.url_redirect_id).to eq(url_redirect.id.to_s)
    end

    it "stores IP address and user agent" do
      post rich_content_page_views_path, params: valid_params, headers: {
        "REMOTE_ADDR" => "192.168.1.100",
        "HTTP_USER_AGENT" => "TestBrowser/1.0"
      }

      view = RichContentPageView.last
      expect(view.ip_address).to eq("192.168.1.100")
      expect(view.user_agent).to eq("TestBrowser/1.0")
    end

    it "returns bad request when page_id is missing" do
      post rich_content_page_views_path, params: { url_redirect_id: url_redirect.id }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["success"]).to be false
    end

    it "returns bad request when url_redirect_id is missing" do
      post rich_content_page_views_path, params: { page_id: rich_content.external_id }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["success"]).to be false
    end

    it "returns not found when page_id does not exist" do
      post rich_content_page_views_path, params: {
        page_id: "nonexistent",
        url_redirect_id: url_redirect.id
      }

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("Page not found")
    end

    it "returns forbidden when url_redirect_id is invalid" do
      post rich_content_page_views_path, params: {
        page_id: rich_content.external_id,
        url_redirect_id: "invalid"
      }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid access")
    end

    it "returns not found when purchase does not exist" do
      orphaned_redirect = create(:url_redirect, purchase: nil)

      post rich_content_page_views_path, params: {
        page_id: rich_content.external_id,
        url_redirect_id: orphaned_redirect.id
      }

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("Purchase not found")
    end

    it "does not bypass suspended check" do
      expect_any_instance_of(RichContentPageViewsController).not_to receive(:check_suspended)
      post rich_content_page_views_path, params: valid_params
    end
  end
end
