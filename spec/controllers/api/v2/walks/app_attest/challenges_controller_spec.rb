# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::AppAttest::ChallengesController do
  describe "POST create" do
    it "returns a fresh challenge that is consumable exactly once" do
      post :create

      expect(response).to have_http_status(:ok)
      challenge = response.parsed_body["challenge"]
      expect(challenge).to be_present
      expect(WalksAppAttestChallenge.consume!(challenge)).to be(true)
      expect(WalksAppAttestChallenge.consume!(challenge)).to be(false)
    end

    it "issues a distinct challenge per call" do
      post :create
      first = response.parsed_body["challenge"]
      post :create
      second = response.parsed_body["challenge"]

      expect(first).to be_present
      expect(second).to be_present
      expect(first).not_to eq(second)
    end
  end
end
