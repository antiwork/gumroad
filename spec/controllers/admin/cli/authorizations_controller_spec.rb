# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Admin::Cli::AuthorizationsController, type: :controller, inertia: true do
  render_views

  let(:admin_user) { create(:admin_user, name: "Admin User", email: "admin@example.com") }
  let(:callback) { "http://127.0.0.1:4567/callback" }
  let(:state) { "state-nonce" }
  let(:code_verifier) { "code-verifier" }
  let(:code_challenge) { AdminApiAuthorizationCode.code_challenge_for(code_verifier) }
  let(:authorization_params) { { callback:, state:, code_challenge: } }

  before do
    sign_in admin_user
  end

  describe "GET show" do
    it "renders the authorize page for team members" do
      get :show, params: authorization_params

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq "Admin/Cli/Authorizations/Show"
      expect(inertia.props[:title]).to eq("Authorize CLI")
      expect(inertia.props[:actor]).to eq({ name: "Admin User", email: "admin@example.com" })
      expect(inertia.props[:callback]).to eq(callback)
      expect(inertia.props[:state]).to eq(state)
      expect(inertia.props[:code_challenge]).to eq(code_challenge)
      expect(inertia.props[:authorization_request]).to be_present
    end

    it "rejects callback URLs outside localhost loopback" do
      get :show, params: authorization_params.merge(callback: "https://example.com/callback")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to eq("Invalid CLI authorization request")
    end

    it "uses the admin gate" do
      sign_in create(:user)

      get :show, params: authorization_params

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "creates a one-time authorization code and redirects to the callback with the original state" do
      get :show, params: authorization_params
      signed_authorization_request = inertia.props[:authorization_request]

      expect do
        post :create, params: authorization_params.merge(authorization_request: signed_authorization_request)
      end.to change(AdminApiAuthorizationCode, :count).by(1)

      expect(response).to have_http_status(:see_other)
      redirect_uri = URI.parse(response.location)
      redirect_params = Rack::Utils.parse_nested_query(redirect_uri.query)
      expect("#{redirect_uri.scheme}://#{redirect_uri.host}:#{redirect_uri.port}#{redirect_uri.path}").to eq(callback)
      expect(redirect_params["state"]).to eq(state)
      expect(redirect_params["code"]).to be_present

      plaintext_token, admin_api_token = AdminApiAuthorizationCode.exchange!(code: redirect_params["code"], code_verifier:)
      expect(admin_api_token.actor_user).to eq(admin_user)
      expect(AdminApiToken.authenticate(plaintext_token)).to eq(admin_api_token)
    end

    it "fails closed when the state does not match the signed authorization request" do
      get :show, params: authorization_params
      signed_authorization_request = inertia.props[:authorization_request]

      expect do
        post :create, params: authorization_params.merge(state: "tampered-state", authorization_request: signed_authorization_request)
      end.not_to change(AdminApiAuthorizationCode, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
