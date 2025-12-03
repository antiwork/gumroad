# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::AffiliatesController, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  describe "GET 'index'" do
    context "when there's one matching affiliate in search result" do
      before do
        @affiliate_user = create(:direct_affiliate).affiliate_user
      end

      it "redirects to affiliate's admin page" do
        get :index, params: { query: @affiliate_user.email }

        expect(response).to redirect_to admin_affiliate_path(@affiliate_user.external_id)
      end
    end

    context "when there are multiple affiliates in search result" do
      before do
        @affiliate_users = 10.times.map do
          user = create(:user, name: "test")
          create(:direct_affiliate, affiliate_user: user)
          user
        end
      end

      it "renders search results" do
        get :index, params: { query: "test" }

        expect(response).to be_successful
        expect(inertia.component).to eq("Admin/Affiliates/Index")
        expect(assigns[:users].to_a).to match_array(@affiliate_users)
      end

      it "returns JSON response when requested" do
        get :index, params: { query: "test" }, format: :json

        expect(response).to be_successful
        expect(response.content_type).to match(%r{application/json})
        expect(response.parsed_body["users"].map { _1["id"] }).to match_array(@affiliate_users.drop(5).map(&:external_id))
        expect(response.parsed_body["pagination"]).to be_present
      end
    end
  end

  describe "GET 'show'" do
    let(:affiliate_user) { create(:user, name: "Sam") }

    context "when affiliate account is present" do
      before do
        create(:direct_affiliate, affiliate_user:)
      end

      it "redirects numeric ID to external_id" do
        get :show, params: { external_id: affiliate_user.id }
        expect(response).to redirect_to admin_affiliate_path(affiliate_user.external_id)
      end

      it "returns page successfully with external_id" do
        get :show, params: { external_id: affiliate_user.external_id }

        expect(response).to be_successful
        expect(response.body).to have_text(affiliate_user.name)
        expect(assigns[:title]).to eq "Sam affiliate on Gumroad"
      end
    end

    context "when affiliate account is not present" do
      it "raises ActionController::RoutingError" do
        expect do
          get :show, params: { external_id: affiliate_user.external_id }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
