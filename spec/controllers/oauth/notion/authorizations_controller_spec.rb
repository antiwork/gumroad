# frozen_string_literal: true

require "spec_helper"

describe Oauth::Notion::AuthorizationsController do
  describe "GET new" do
    let(:user) { create(:user) }
    let(:oauth_application) { create(:oauth_application, owner: user, scopes: "unfurl", redirect_uri: "https://example.com") }

    before do
      sign_in user
    end

    it "retrieves Notion Bot token" do
      allow_any_instance_of(NotionApi).to receive(:get_bot_token).with(code: "03a0066c-f0cf-442c-bcd9-sample", user:).and_return(nil)

      get :new, params: { client_id: oauth_application.uid, response_type: "code", scope: "unfurl", code: "03a0066c-f0cf-442c-bcd9-sample", redirect_uri: "https://example.com" }

      expect(response).to be_successful
    end
  end
end
