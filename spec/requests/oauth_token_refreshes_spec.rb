# frozen_string_literal: true

require "spec_helper"

describe "OAuth token refreshes" do
  let(:user) { create(:user) }
  let(:oauth_application) do
    create(
      :oauth_application,
      owner: user,
      scopes: "account edit_profile",
      confidential: false
    )
  end
  let!(:access_token) do
    create(
      "doorkeeper/access_token",
      application: oauth_application,
      resource_owner_id: user.id,
      scopes: "account edit_profile",
      use_refresh_token: true
    )
  end

  it "refreshes a token with scopes allowed by the application" do
    expect do
      post oauth_token_path,
           params: {
             grant_type: "refresh_token",
             refresh_token: access_token.refresh_token,
             client_id: oauth_application.uid,
             scope: "account"
           }
    end.to change(Doorkeeper::AccessToken, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("scope" => "account")
    expect(Doorkeeper::AccessToken.last).to have_attributes(
      application_id: oauth_application.id,
      resource_owner_id: user.id,
      scopes: Doorkeeper::OAuth::Scopes.from_string("account")
    )
  end

  it "returns the standard error when the refresh token is missing" do
    post oauth_token_path,
         params: {
           grant_type: "refresh_token",
           client_id: oauth_application.uid
         }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to include("error" => "invalid_request")
  end
end
