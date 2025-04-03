# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Oauth::ApplicationsController do
  shared_examples_for "redirects to page with OAuth apps" do
    it "redirects to settings_advanced_path" do
      raise "no @action in before block of test" unless @action
      raise "no @params in before block of test" unless @params

      get @action, params: @params
      expect(response).to redirect_to settings_advanced_path
    end
  end

  describe "GET index" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "redirects to page with OAuth apps"
  end

  describe "GET new" do
    before do
      @action = :new
      @params = {}
    end

    it_behaves_like "redirects to page with OAuth apps"
  end

  describe "GET show" do
    before do
      @action = :new
      @params = {}
    end

    it_behaves_like "redirects to page with OAuth apps"
  end

  let(:other_user) { create(:user) }
  let(:seller) { create(:named_seller) }
  let(:app) { create(:oauth_application, owner: seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    let(:params) do {
      oauth_application: {
        name: "appname",
        redirect_uri: "http://hi"
      }
    } end

    it "adds a new application" do
      expect { post(:create, params:) }.to change { seller.oauth_applications.count }.by 1
      expect(response.parsed_body["success"]).to eq(true)
    end

    it "returns a url redirect to the application's page" do
      post(:create, params:)
      id = OauthApplication.last.external_id
      expect(response.parsed_body["redirect_location"]).to eq(oauth_application_path(id))
    end

    it "creates a new application with no revenue share" do
      expect { post(:create, params:) }.to change { OauthApplication.count }.by 1
      expect(OauthApplication.last.affiliate_basis_points).to eq nil
    end
  end

  describe "GET edit" do
    let(:params) { { id: app.external_id } }

    context "when logged in user does not own the app" do
      before do
        sign_in other_user
      end

      it "does not set a valid access token" do
        get(:edit, params:)

        expect(assigns(:access_token)).to be(nil)
      end

      it "redirects" do
        get(:edit, params:)

        expect(response).to redirect_to(oauth_applications_path)
      end
    end

    it "sets the application" do
      get(:edit, params:)
      expect(assigns(:application)).to eq(app)
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { app }
      let(:policy_klass) { Settings::AuthorizedApplications::OauthApplicationPolicy }
      let(:request_params) { params }
    end

    it "returns http success and assigns correct instance variables" do
      get(:edit, params:)

      expect(response).to be_successful
      expect(assigns(:application)).to eq(app)
      pundit_user = SellerContext.new(user: user_with_role_for_seller, seller:)
      expect(assigns(:react_component_props)).to eq(SettingsPresenter.new(pundit_user:).application_props(app))
    end

    it "renders the right template" do
      get(:edit, params:)
      expect(response).to render_template(:edit)
    end

    context "when application has been deleted" do
      before do
        app.mark_deleted!
      end

      it "redirects to settings page with an alert" do
        get(:edit, params:)
        expect(flash[:alert]).to eq("Application not found or you don't have the permissions to modify it.")
        expect(response).to redirect_to(oauth_applications_path)
      end
    end
  end

  describe "PUT update" do
    let(:params) { {} }

    context "when logged in user does not own the app" do
      let(:params) { { id: app.external_id } }

      before do
        sign_in other_user
      end

      it "redirects" do
        put(:update, params:)

        expect(response).to redirect_to(oauth_applications_path)
      end
    end

    context "when logged in user is admin of owner account" do
      let(:params) { { id: app.external_id } }

      it "sets the application" do
        put(:update, params:)

        expect(assigns(:application)).to eq(app)
      end
    end

    context "when logged in user owns the app" do
      let(:newappname) { app.name + "more" }
      let(:params) { { id: app.external_id, oauth_application: { name: newappname } } }

      it_behaves_like "authorize called for action", :put, :update do
        let(:record) { app }
        let(:policy_klass) { Settings::AuthorizedApplications::OauthApplicationPolicy }
        let(:request_params) { params }
      end

      it "sets the application" do
        put(:update, params:)

        expect(assigns(:application)).to eq(app)
      end

      it "updates the application" do
        put(:update, params:)

        expect(response.status).to eq(200)
        expect(app.reload.name).to eq(newappname)
      end

      it "returns the right json" do
        put(:update, params:)

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["message"]).to eq("Application updated.")
      end

      describe "bad update params" do
        let(:params) { { id: app.external_id, oauth_application: { redirect_uri: "foo" } } }

        it "returns the right json" do
          put(:update, params:)

          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to eq("Redirect URI must be an absolute URI.")
        end
      end
    end

    describe "if application has been deleted" do
      let(:params) { { id: app.external_id } }

      before do
        app.mark_deleted!
      end

      it "redirects to settings page with an alert" do
        put(:update, params:)

        expect(flash[:alert]).to eq("Application not found or you don't have the permissions to modify it.")
        expect(response).to redirect_to(oauth_applications_path)
      end
    end
  end

  describe "DELETE destroy" do
    let(:params) { { id: app.external_id } }

    before do
      create(:resource_subscription, oauth_application: app)
    end

    describe "if logged in user does not own the app" do
      before do
        sign_in other_user
      end

      it "redirects" do
        delete(:destroy, params:)

        expect(response).to redirect_to(oauth_applications_path)
      end

      it "does not delete application" do
        delete(:destroy, params:)

        expect(OauthApplication.last.deleted_at).to be(nil)
      end
    end

    context "when logged in user is admin of owner account" do
      it "sets the application" do
        delete(:destroy, params:)

        expect(assigns(:application)).to eq(app)
      end
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { app }
      let(:policy_klass) { Settings::AuthorizedApplications::OauthApplicationPolicy }
      let(:request_params) { params }
    end

    it "sets the application" do
      delete(:destroy, params:)

      expect(assigns(:application)).to eq(app)
    end

    it "marks the application and its resource subscriptions as deleted" do
      delete(:destroy, params:)

      expect(OauthApplication.last.deleted_at).to be_present
      expect(OauthApplication.last.resource_subscriptions.alive.count).to eq(0)
    end

    it "return a successful response" do
      delete(:destroy, params:)

      expect(response).to have_http_status(:ok)
    end

    describe "if application has been deleted" do
      before do
        app.mark_deleted!
      end

      it "redirects to settings page with an alert" do
        delete(:destroy, params:)

        expect(flash[:alert]).to eq("Application not found or you don't have the permissions to modify it.")
        expect(response).to redirect_to(oauth_applications_path)
      end
    end
  end
end
