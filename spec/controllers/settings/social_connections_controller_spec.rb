# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::SocialConnectionsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  before { sign_in seller }

  it_behaves_like "authorize called for controller", Settings::SocialConnectionsPolicy do
    let(:record) { :social_connections }
  end

  describe "GET show" do
    it "renders the Social connections page for the owner" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/SocialConnections/Show")
      expect(inertia.props[:twitter_connected]).to eq(false)
      expect(inertia.props[:settings_pages]).to include("social_connections")
    end

    it "issues a session-bound return token only for the owner entering from onboarding" do
      get :show, params: { social_connect_origin: "onboarding" }
      expect(inertia.props[:social_connect_return]).to be_present
      expect(session[:social_connect_return]).to include("token" => inertia.props[:social_connect_return], "user_id" => seller.id)
    end

    it "preserves pending intent on an onboarding reload without extending its expiry" do
      get :show, params: { social_connect_origin: "onboarding" }
      context = session[:social_connect_return].dup
      travel 5.minutes do
        get :show, params: { social_connect_origin: "onboarding" }
      end
      expect(session[:social_connect_return]).to eq(context)
      expect(inertia.props[:social_connect_return]).to eq(context["token"])
    end

    it "rejects arbitrary origins and clears abandoned intent on a normal visit" do
      session[:social_connect_return] = { "token" => "abandoned" }
      get :show, params: { social_connect_origin: "https://example.org" }
      expect(inertia.props[:social_connect_return]).to be_nil
      expect(session[:social_connect_return]).to be_nil
      get :show, params: { social_connect_origin: "onboarding" }
      get :show
      expect(session[:social_connect_return]).to be_nil
    end

    context "as a team admin" do
      include_context "with user signed in as admin for seller"

      it "redirects unauthorized team members and omits the nav entry" do
        get :show

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to be_present
        presenter = SettingsPresenter.new(pundit_user: SellerContext.new(user: user_with_role_for_seller, seller:))
        expect(presenter.pages).not_to include("social_connections")
      end
    end
  end
end
