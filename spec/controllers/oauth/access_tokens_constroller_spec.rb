# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Oauth::AccessTokensController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::AuthorizedApplications::OauthApplicationPolicy do
    let(:record) { create(:oauth_application, owner: seller) }
    let(:request_params) { { application_id: record.external_id } }
  end

  describe "POST create" do
    context "when user owns the application" do
      before do
        @oauth_application = create(:oauth_application, owner: seller)
      end

      it "creates an access token" do
        expect do
          post :create, params: { application_id: @oauth_application.external_id }, session: { format: :json }
        end.to change { Doorkeeper::AccessToken.count }.by(1)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["token"]).to eq(@oauth_application.access_tokens.last.token)
      end
    end

    context "when user does not own the application" do
      before do
        @oauth_application = create(:oauth_application)
      end

      it "returns 401 Unauthorized" do
        expect do
          post :create, params: { application_id: @oauth_application.external_id }, session: { format: :json }
        end.to_not change { Doorkeeper::AccessToken.count }

        expect(response).to be_not_found
        expect(response.parsed_body["success"]).to eq(false)
      end
    end

    context "when application has been deleted" do
      before do
        @oauth_application = create(:oauth_application, owner: seller)
        @oauth_application.mark_deleted!
      end

      it "does not create an access token" do
        expect do
          post :create, params: { application_id: @oauth_application.external_id }, session: { format: :json }
        end.not_to change { Doorkeeper::AccessToken.count }

        expect(response).to be_not_found
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Application not found or you don't have the permissions to modify it.")
      end
    end
  end
end
