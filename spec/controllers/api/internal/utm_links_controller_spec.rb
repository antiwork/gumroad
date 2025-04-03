# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::UtmLinksController do
  let(:seller) { create(:user) }

  before do
    Feature.activate_user(:utm_links, seller)
  end

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { UtmLink }
    end

    it "returns seller's paginated alive UTM links" do
      utm_link1 = create(:utm_link, seller:, created_at: 1.day.ago)
      _utm_link2 = create(:utm_link, seller:, deleted_at: DateTime.current)
      utm_link3 = create(:utm_link, seller:, disabled_at: DateTime.current, created_at: 2.days.ago)

      stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 1)

      get :index, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props).to match(PaginatedUtmLinksPresenter.new(seller:).props)
      expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link1).utm_link_props])
      expect(props[:pagination]).to eq(pages: 2, page: 1)

      get :index, params: { page: 2 }, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props).to match(PaginatedUtmLinksPresenter.new(seller:, page: 2).props)
      expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link3).utm_link_props])
      expect(props[:pagination]).to eq(pages: 2, page: 2)

      # When the page is greater than the number of pages, it returns the last page
      expect do
        get :index, params: { page: 3 }, format: :json

        expect(response).to be_successful
        props = response.parsed_body.deep_symbolize_keys
        expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link3).utm_link_props])
        expect(props[:pagination]).to eq(pages: 2, page: 2)
      end.not_to raise_error
    end

    it "sorts by date in descending order by default" do
      utm_link1 = create(:utm_link, seller:, created_at: 1.day.ago)
      utm_link2 = create(:utm_link, seller:, created_at: 3.days.ago)
      utm_link3 = create(:utm_link, seller:, created_at: 2.days.ago)

      get :index, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { |l| l[:id] }).to eq([
                                                           utm_link1.external_id,
                                                           utm_link3.external_id,
                                                           utm_link2.external_id
                                                         ])
    end

    it "sorts UTM links by the specified column" do
      create(:utm_link, seller:, title: "C Link", created_at: 1.day.ago)
      create(:utm_link, seller:, title: "A Link", created_at: 3.days.ago)
      create(:utm_link, seller:, title: "B Link", created_at: 2.days.ago)

      get :index, params: { sort: { key: "link", direction: "asc" } }, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { _1[:title] }).to eq([
                                                           "A Link",
                                                           "B Link",
                                                           "C Link"
                                                         ])

      get :index, params: { sort: { key: "link", direction: "desc" } }, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { _1[:title] }).to eq([
                                                           "C Link",
                                                           "B Link",
                                                           "A Link"
                                                         ])
    end

    it "filters UTM links by search query" do
      utm_link1 = create(:utm_link, seller:, title: "Facebook Campaign", utm_source: "facebook")
      utm_link2 = create(:utm_link, seller:, title: "Twitter Campaign", utm_source: "twitter")

      get :index, params: { query: "Facebook" }, format: :json
      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { _1[:id] }).to eq([utm_link1.external_id])

      get :index, params: { query: "twitter" }, format: :json
      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { _1[:id] }).to eq([utm_link2.external_id])

      get :index, params: { query: "Campaign" }, format: :json
      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id])

      get :index, params: { query: "nonexistent" }, format: :json
      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links]).to be_empty

      get :index, params: { query: "     " }, format: :json
      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id])
    end
  end

  describe "GET new" do
    it_behaves_like "authentication required for action", :get, :new

    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { UtmLink }
    end

    it "returns React props for rendering the new page" do
      get :new, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expected_props = UtmLinkPresenter.new(seller:).new_page_react_props
      expected_props[:context][:short_url] = props[:context][:short_url]
      expect(props).to eq(expected_props)
    end

    it "returns React props for rendering the new page with a copy from an existing UTM link" do
      existing_utm_link = create(:utm_link, seller:)
      get :new, params: { copy_from: existing_utm_link.external_id }, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expected_props = UtmLinkPresenter.new(seller:).new_page_react_props(copy_from: existing_utm_link.external_id)
      expected_short_url = props[:context][:short_url]
      expected_props[:context][:short_url] = expected_short_url
      expected_props[:utm_link][:short_url] = expected_short_url
      expect(props).to eq(expected_props)
    end
  end

  describe "POST create" do
    let!(:product) { create(:product, user: seller) }
    let!(:audience_post) { create(:audience_post, :published, shown_on_profile: true, seller:) }
    let(:params) do
      {
        utm_link: {
          title: "Test Link",
          target_resource_id: product.external_id,
          target_resource_type: "product_page",
          permalink: "abc12345",
          utm_source: "facebook",
          utm_medium: "social",
          utm_campaign: "summer",
        }
      }
    end

    it_behaves_like "authentication required for action", :post, :create

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { UtmLink }
    end

    it "creates a UTM link" do
      request.remote_ip = "192.168.1.1"
      cookies[:_gumroad_guid] = "1234567890"

      expect do
        post :create, params:, as: :json
      end.to change { seller.utm_links.count }.by(1)

      expect(response).to be_successful

      utm_link = seller.utm_links.last
      expect(utm_link.title).to eq("Test Link")
      expect(utm_link.target_resource_type).to eq("product_page")
      expect(utm_link.target_resource_id).to eq(product.id)
      expect(utm_link.permalink).to eq("abc12345")
      expect(utm_link.utm_source).to eq("facebook")
      expect(utm_link.utm_medium).to eq("social")
      expect(utm_link.utm_campaign).to eq("summer")
      expect(utm_link.ip_address).to eq("192.168.1.1")
      expect(utm_link.browser_guid).to eq("1234567890")
    end

    it "returns an error if the target resource id is missing" do
      params[:utm_link][:target_resource_id] = nil

      expect do
        post :create, params:, as: :json
      end.not_to change { UtmLink.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({
                                           "error" => "can't be blank",
                                           "attr_name" => "target_resource_id"
                                         })
    end

    it "returns an error if the permalink is invalid" do
      params[:utm_link][:permalink] = "abc"

      expect do
        post :create, params:, as: :json
      end.not_to change { UtmLink.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({
                                           "error" => "is invalid",
                                           "attr_name" => "permalink"
                                         })
    end

    it "returns an error if the UTM source is missing" do
      params[:utm_link][:utm_source] = nil

      expect do
        post :create, params:, as: :json
      end.not_to change { UtmLink.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({
                                           "error" => "can't be blank",
                                           "attr_name" => "utm_source"
                                         })
    end

    it "returns error for missing required param" do
      expect do
        post :create, params: {}, as: :json
      end.to raise_error(ActionController::ParameterMissing, /param is missing or the value is empty: utm_link/)
    end

    it "allows creating a link with same UTM params but different target resource" do
      existing_utm_link = create(:utm_link, seller:, utm_source: "facebook", utm_medium: "social", utm_campaign: "summer", target_resource_type: "profile_page")

      post :create, params:, as: :json

      expect(response).to be_successful
      expect(UtmLink.count).to eq(2)
      created_utm_link = UtmLink.last
      expect(created_utm_link.utm_source).to eq(existing_utm_link.utm_source)
      expect(created_utm_link.utm_medium).to eq(existing_utm_link.utm_medium)
      expect(created_utm_link.utm_campaign).to eq(existing_utm_link.utm_campaign)
      expect(created_utm_link.utm_content).to eq(existing_utm_link.utm_content)
      expect(created_utm_link.utm_term).to eq(existing_utm_link.utm_term)
      expect([created_utm_link.target_resource_type, created_utm_link.target_resource_id]).to_not eq([existing_utm_link.target_resource_type, existing_utm_link.target_resource_id])
    end

    it "does not allow creating a link with same UTM params and same target resource" do
      create(:utm_link, seller:, utm_source: "facebook", utm_medium: "social", utm_campaign: "summer", target_resource_type: "product_page", target_resource_id: product.id)

      expect do
        post :create, params:, as: :json
      end.not_to change { UtmLink.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({
                                           "error" => "A link with similar UTM parameters already exists for this destination!",
                                           "attr_name" => "target_resource_id"
                                         })
    end
  end

  describe "GET edit" do
    subject(:utm_link) { create(:utm_link, seller:) }

    it_behaves_like "authentication required for action", :get, :edit do
      let(:request_params) { { id: utm_link.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id } }
    end

    it "returns React props for rendering the edit page" do
      get :edit, params: { id: utm_link.external_id }, format: :json

      expect(response).to be_successful
      props = response.parsed_body.deep_symbolize_keys
      expect(props).to eq(UtmLinkPresenter.new(seller:, utm_link:).edit_page_react_props)
    end
  end

  describe "PATCH update" do
    subject(:utm_link) { create(:utm_link, seller:, ip_address: "192.168.1.1", browser_guid: "1234567890") }
    let!(:product) { create(:product, user: seller) }
    let(:params) do
      {
        id: utm_link.external_id,
        utm_link: {
          title: "Updated Title",
          target_resource_id: product.external_id,
          target_resource_type: "product_page",
          permalink: "abc12345",
          utm_source: "facebook",
          utm_medium: "social",
          utm_campaign: "summer",
        }
      }
    end

    it_behaves_like "authentication required for action", :patch, :update do
      let(:request_params) { params }
    end

    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { utm_link }
      let(:request_params) { params }
    end

    it "updates only the permitted params of the UTM link" do
      request.remote_ip = "172.0.0.1"
      cookies[:_gumroad_guid] = "9876543210"

      old_permalink = utm_link.permalink

      patch :update, params: params, as: :json

      expect(response).to be_successful
      expect(utm_link.reload.title).to eq("Updated Title")
      expect(utm_link.target_resource_id).to be_nil
      expect(utm_link.target_resource_type).to eq("profile_page")
      expect(utm_link.permalink).to eq(old_permalink)
      expect(utm_link.utm_source).to eq("facebook")
      expect(utm_link.utm_medium).to eq("social")
      expect(utm_link.utm_campaign).to eq("summer")
      expect(utm_link.ip_address).to eq("192.168.1.1")
      expect(utm_link.browser_guid).to eq("1234567890")
    end

    it "returns an error if the UTM source is missing" do
      params[:utm_link][:utm_source] = nil

      patch :update, params:, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({
                                           "error" => "can't be blank",
                                           "attr_name" => "utm_source"
                                         })
    end

    it "returns an error if the UTM link does not exist" do
      params[:id] = "does-not-exist"

      expect do
        patch :update, params:, as: :json
      end.not_to change { utm_link.reload }

      expect(response).to have_http_status(:not_found)
    end

    it "returns an error if the UTM link does not belong to the seller" do
      utm_link.update!(seller: create(:user))

      expect do
        patch :update, params:, as: :json
      end.not_to change { utm_link.reload }

      expect(response).to have_http_status(:not_found)
    end

    it "returns an error if the UTM link is deleted" do
      utm_link.mark_deleted!

      expect do
        patch :update, params:, as: :json
      end.not_to change { utm_link.reload }

      expect(response).to have_http_status(:not_found)
    end

    it "returns an error for missing required param" do
      expect do
        patch :update, params: { id: utm_link.external_id, utm_link: {} }, as: :json
      end.to raise_error(ActionController::ParameterMissing, /param is missing or the value is empty: utm_link/)
    end
  end

  describe "DELETE destroy" do
    subject(:utm_link) { create(:utm_link, seller:) }

    it_behaves_like "authentication required for action", :delete, :destroy do
      let(:request_params) { { id: utm_link.external_id } }
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id } }
    end

    it "fails if the UTM link does not belong to the seller" do
      utm_link = create(:utm_link)

      expect do
        delete :destroy, params: { id: utm_link.external_id }, format: :json
      end.to_not change { utm_link.reload.deleted_at }

      expect(response).to have_http_status(:not_found)
    end

    it "fails if the UTM link does not exist" do
      expect do
        delete :destroy, params: { id: "does-not-exist" }, format: :json
      end.to_not change { UtmLink.alive.count }

      expect(response).to have_http_status(:not_found)
    end

    it "soft deletes the UTM link" do
      expect do
        delete :destroy, params: { id: utm_link.external_id }, format: :json
      end.to change { utm_link.reload.deleted_at }.from(nil).to(be_within(5.seconds).of(DateTime.current))

      expect(response).to be_successful
      expect(utm_link.reload).to be_deleted
    end
  end
end
