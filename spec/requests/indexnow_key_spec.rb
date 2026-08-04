# frozen_string_literal: true

require "spec_helper"

describe "IndexNow key file", type: :request do
  let(:key) { "b" * 32 }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("INDEXNOW_KEY").and_return(key)
  end

  describe "GET /{key}.txt" do
    it "serves the key as plain text" do
      get "/#{key}.txt", headers: { "HOST" => DOMAIN }

      expect(response.status).to eq(200)
      expect(response.body).to eq(key)
      expect(response.media_type).to eq("text/plain")
    end

    it "serves the key on a seller subdomain host" do
      seller = create(:user, username: "indexnowseller")

      get "/#{key}.txt", headers: { "HOST" => URI("#{seller.subdomain_with_protocol}").host }

      expect(response.status).to eq(200)
      expect(response.body).to eq(key)
    end

    it "returns 404 for a different key" do
      get "/#{"c" * 32}.txt", headers: { "HOST" => DOMAIN }

      expect(response.status).to eq(404)
    end

    it "serves a key using the full IndexNow charset (uppercase and hyphens)" do
      mixed_key = "AbCd-1234-EfGh-5678"

      allow(GlobalConfig).to receive(:get).with("INDEXNOW_KEY").and_return(mixed_key)
      get "/#{mixed_key}.txt", headers: { "HOST" => DOMAIN }

      expect(response.status).to eq(200)
      expect(response.body).to eq(mixed_key)
    end

    context "when the key is not configured" do
      let(:key) { nil }

      it "returns 404" do
        get "/#{"d" * 32}.txt", headers: { "HOST" => DOMAIN }

        expect(response.status).to eq(404)
      end
    end
  end
end
