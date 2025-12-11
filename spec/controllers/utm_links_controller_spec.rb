# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe UtmLinksController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:utm_link) { create(:utm_link, seller:) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:utm_links, seller)
  end

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { UtmLink }
    end

    it "returns unauthorized response if the :utm_links feature flag is disabled" do
      Feature.deactivate_user(:utm_links, seller)

      get :index

      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
    end

    it "renders successfully with Inertia" do
      get :index
      expect(response).to be_successful
      expect(inertia.component).to eq("UtmLinks/Index")
      expect(inertia.props[:utm_links]).to be_an(Array)
      expect(inertia.props[:pagination]).to be_present
    end

    it "returns seller's paginated UTM links" do
      utm_link1 = create(:utm_link, seller:, created_at: 1.day.ago)
      _deleted_link = create(:utm_link, seller:, deleted_at: DateTime.current)
      utm_link2 = create(:utm_link, seller:, created_at: 2.days.ago)

      get :index

      expect(response).to be_successful
      props = inertia.props
      expect(props[:utm_links].map { |l| l[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id])
    end

    it "filters UTM links by search query" do
      utm_link1 = create(:utm_link, seller:, title: "Facebook Campaign")
      _utm_link2 = create(:utm_link, seller:, title: "Twitter Campaign")

      get :index, params: { query: "Facebook" }

      expect(response).to be_successful
      props = inertia.props
      expect(props[:utm_links].map { |l| l[:id] }).to eq([utm_link1.external_id])
      expect(props[:query]).to eq("Facebook")
    end

    it "sorts UTM links by the specified column" do
      create(:utm_link, seller:, title: "C Link", created_at: 1.day.ago)
      create(:utm_link, seller:, title: "A Link", created_at: 3.days.ago)
      create(:utm_link, seller:, title: "B Link", created_at: 2.days.ago)

      get :index, params: { key: "link", direction: "asc" }

      expect(response).to be_successful
      props = inertia.props
      expect(props[:utm_links].map { _1[:title] }).to eq(["A Link", "B Link", "C Link"])
      expect(props[:sort].permit!.to_h).to eq({ "key" => "link", "direction" => "asc" })
    end
  end

  describe "GET new" do
    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { UtmLink }
    end

    it "renders successfully with Inertia" do
      get :new
      expect(response).to be_successful
      expect(inertia.component).to eq("UtmLinks/New")
      expect(inertia.props[:context]).to be_present
    end

    it "returns props for duplicating an existing UTM link" do
      existing_utm_link = create(:utm_link, seller:)

      get :new, params: { copy_from: existing_utm_link.external_id }

      expect(response).to be_successful
      expect(inertia.props[:utm_link]).to be_present
      expect(inertia.props[:utm_link][:title]).to eq(existing_utm_link.title)
    end
  end

  describe "POST create" do
    let(:valid_params) do
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

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { UtmLink }
      let(:request_params) { valid_params }
    end

    it "creates a UTM link and redirects with success message" do
      expect do
        post :create, params: valid_params
      end.to change { seller.utm_links.count }.by(1)

      expect(response).to redirect_to(utm_links_dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Link created!")

      utm_link = seller.utm_links.last
      expect(utm_link.title).to eq("Test Link")
      expect(utm_link.utm_source).to eq("facebook")
    end

    it "redirects back to new with errors when validation fails" do
      valid_params[:utm_link][:utm_source] = nil

      expect do
        post :create, params: valid_params
      end.not_to change { UtmLink.count }

      expect(response).to redirect_to(new_utm_link_dashboard_path)
      expect(flash[:alert]).to be_present
    end
  end

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id } }
    end

    it "renders successfully with Inertia" do
      get :edit, params: { id: utm_link.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("UtmLinks/Edit")
      expect(inertia.props[:utm_link]).to be_present
      expect(inertia.props[:context]).to be_present
    end

    context "when UTM link doesn't exist" do
      it "returns 404" do
        expect { get :edit, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "PATCH update" do
    let(:update_params) do
      {
        id: utm_link.external_id,
        utm_link: {
          title: "Updated Title",
          utm_source: "twitter",
          utm_medium: "social",
          utm_campaign: "winter",
        }
      }
    end

    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { utm_link }
      let(:request_params) { update_params }
    end

    it "updates the UTM link and redirects with success message" do
      patch :update, params: update_params

      expect(response).to redirect_to(utm_links_dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Link updated!")
      expect(utm_link.reload.title).to eq("Updated Title")
    end

    it "redirects back to edit with errors when validation fails" do
      update_params[:utm_link][:utm_source] = nil

      patch :update, params: update_params

      expect(response).to redirect_to(edit_utm_link_dashboard_path(utm_link.external_id))
      expect(flash[:alert]).to be_present
    end

    context "when UTM link is deleted" do
      it "returns 404" do
        utm_link.mark_deleted!

        expect do
          patch :update, params: update_params
        end.to raise_error(ActionController::RoutingError)
      end
    end

    context "when UTM link doesn't exist" do
      it "returns 404" do
        update_params[:id] = "nonexistent"

        expect do
          patch :update, params: update_params
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "DELETE destroy" do
    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id } }
    end

    it "soft deletes the UTM link and redirects with success message" do
      delete :destroy, params: { id: utm_link.external_id }

      expect(response).to redirect_to(utm_links_dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Link deleted!")
      expect(utm_link.reload.deleted_at).to be_present
    end

    context "when UTM link doesn't belong to seller" do
      it "returns 404" do
        other_utm_link = create(:utm_link)

        expect do
          delete :destroy, params: { id: other_utm_link.external_id }
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
