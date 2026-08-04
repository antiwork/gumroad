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

    it "returns 404 for a different key" do
      get "/#{"c" * 32}.txt", headers: { "HOST" => DOMAIN }

      expect(response.status).to eq(404)
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
