# frozen_string_literal: true

require "spec_helper"

describe NotionApi, :vcr do
  let(:user) { create(:user, email: "user@example.com") }

  describe "#get_bot_token" do
    before do
      allow(GlobalConfig).to receive(:get).and_return(nil)
      allow(GlobalConfig).to receive(:get).with("NOTION_OAUTH_CLIENT_ID").and_return("id-1234")
      allow(GlobalConfig).to receive(:get).with("NOTION_OAUTH_CLIENT_SECRET").and_return("secret-1234")
    end

    it "retrieves Notion access token" do
      result = described_class.new.get_bot_token(code: "03a0066c-f0cf-442c-bcd9-sample", user:)

      expect(result.parsed_response).to include(
        "access_token" => "secret_cKEExFXDe4r0JxyDDwdqhO9rpMKJ_SAMPLE",
        "bot_id" => "e511ea88-8c43-410d-848f-0e2804aab14d",
        "token_type" => "bearer"
      )
    end
  end
end
