# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::AppAttest::AttestationsController do
  describe "POST create" do
    let(:params) { { key_id: "k", attestation: "ZGVhZGJlZWY=", challenge: "c" } }

    it "returns 201 with the key id when the verifier accepts" do
      key = build_stubbed(:walks_app_attest_key, key_id: "abc", attested_at: Time.current)
      allow(WalksAppAttestVerifier).to receive(:attest)
        .with(hash_including(key_id: "k"))
        .and_return(WalksAppAttestVerifier::Result.new(valid?: true, key: key))

      post :create, params: params

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["key_id"]).to eq("abc")
    end

    it "returns 422 with the verifier reason when rejected" do
      allow(WalksAppAttestVerifier).to receive(:attest)
        .and_return(WalksAppAttestVerifier::Result.new(valid?: false, error: :bad_chain))

      post :create, params: params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["reason"]).to eq("bad_chain")
    end
  end
end
