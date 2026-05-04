# frozen_string_literal: true

require "spec_helper"

describe Oauth::AuthorizationsController, type: :controller do
  render_views

  let(:admin_user) { create(:admin_user, name: "Admin User", email: "admin@example.com") }
  let(:user) { create(:user) }
  let(:owner) { create(:user) }
  let(:redirect_uri) { "http://gumroad.com/callback" }
  let(:application) { create(:oauth_application, owner:, redirect_uri:, confidential: false) }
  let(:state) { "seller-state" }
  let(:code_verifier) { "test-verifier" }
  let(:code_challenge) { AdminApiAuthorizationCode.code_challenge_for(code_verifier) }
  let(:oauth_params) do
    {
      response_type: "code",
      client_id: application.uid,
      redirect_uri:,
      scope: "edit_products",
      state:,
      code_challenge:,
      code_challenge_method: "S256"
    }
  end

  before do
    sign_in admin_user
  end

  describe "GET new" do
    it "renders an unchecked admin authorization checkbox for admin users when admin scope is optional" do
      get :new, params: oauth_params.merge(admin_scope: "optional")

      document = Nokogiri::HTML(response.body)
      checkbox = document.at_css("input[type='checkbox'][name='authorize_admin_operations']")
      admin_scope_field = document.at_css("input[type='hidden'][name='admin_scope']")

      expect(response).to have_http_status(:ok)
      expect(document.text).to include("Also authorize admin operations on this machine")
      expect(checkbox).to be_present
      expect(checkbox["checked"]).to be_nil
      expect(admin_scope_field["value"]).to eq("optional")
    end

    it "does not render the admin authorization checkbox for non-admin users" do
      sign_in user

      get :new, params: oauth_params.merge(admin_scope: "optional")

      document = Nokogiri::HTML(response.body)
      expect(document.text).not_to include("Also authorize admin operations on this machine")
      expect(document.at_css("input[type='checkbox'][name='authorize_admin_operations']")).to be_nil
    end

    it "does not change the existing authorization page when admin scope is absent" do
      get :new, params: oauth_params

      document = Nokogiri::HTML(response.body)
      expect(document.text).to include("Authorize")
      expect(document.text).not_to include("Also authorize admin operations on this machine")
      expect(document.at_css("input[type='hidden'][name='admin_scope']")).to be_nil
    end
  end

  describe "POST create" do
    it "creates an admin authorization code and redirects with seller and admin codes when admin user opts in" do
      expect do
        post :create, params: oauth_params.merge(admin_scope: "optional", authorize_admin_operations: "1")
      end.to change(AdminApiAuthorizationCode, :count).by(1)

      redirect_params = redirect_query_params
      admin_authorization_code = AdminApiAuthorizationCode.last

      expect(redirect_params["code"]).to be_present
      expect(redirect_params["state"]).to eq(state)
      expect(redirect_params["admin_code"]).to be_present
      expect(admin_authorization_code.actor_user).to eq(admin_user)
      expect(admin_authorization_code.code_challenge).to eq(code_challenge)
      expect(AdminApiAuthorizationCode.exchange!(code: redirect_params["admin_code"], code_verifier:).last.actor_user).to eq(admin_user)
    end

    it "redirects with the seller code only when admin user leaves admin authorization unchecked" do
      expect do
        post :create, params: oauth_params.merge(admin_scope: "optional")
      end.not_to change(AdminApiAuthorizationCode, :count)

      redirect_params = redirect_query_params
      expect(redirect_params["code"]).to be_present
      expect(redirect_params["state"]).to eq(state)
      expect(redirect_params).not_to have_key("admin_code")
    end

    it "does not create an admin authorization code for non-admin users with tampered params" do
      sign_in user

      expect do
        post :create, params: oauth_params.merge(admin_scope: "optional", authorize_admin_operations: "1")
      end.not_to change(AdminApiAuthorizationCode, :count)

      redirect_params = redirect_query_params
      expect(redirect_params["code"]).to be_present
      expect(redirect_params).not_to have_key("admin_code")
    end

    it "keeps existing authorization behavior when admin scope is absent" do
      expect do
        post :create, params: oauth_params.merge(authorize_admin_operations: "1")
      end.not_to change(AdminApiAuthorizationCode, :count)

      redirect_params = redirect_query_params
      expect(redirect_params["code"]).to be_present
      expect(redirect_params["state"]).to eq(state)
      expect(redirect_params).not_to have_key("admin_code")
    end
  end

  def redirect_query_params
    uri = URI.parse(response.location)
    Rack::Utils.parse_nested_query(uri.query)
  end
end
