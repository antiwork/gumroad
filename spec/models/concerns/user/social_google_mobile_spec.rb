# frozen_string_literal: true

require "spec_helper"

describe User::SocialGoogleMobile do
  let(:key_source) { instance_double(Google::Auth::IDTokens::JwkHttpKeySource) }
  let(:verifier) { instance_double(Google::Auth::IDTokens::Verifier) }
  let(:user) { create(:user) }
  let(:payload) { { "aud" => GlobalConfig.get("GOOGLE_CLIENT_ID"), "email" => user.email, "email_verified" => true } }

  before do
    allow(Google::Auth::IDTokens::JwkHttpKeySource).to receive(:new).and_return(key_source)
    allow(Google::Auth::IDTokens::Verifier).to receive(:new).and_return(verifier)
    allow(verifier).to receive(:verify).and_return(payload)
  end

  describe ".find_for_google_mobile_auth" do
    context "when audience matches the client_id" do
      context "when the email is verified" do
        it "returns the user" do
          expect(User.find_for_google_mobile_auth(google_id_token: "token")).to eq user
        end
      end

      context "when the email is not verified" do
        let(:payload) { { "aud" => GlobalConfig.get("GOOGLE_CLIENT_ID"), "email" => user.email, "email_verified" => false } }

        it "returns nil" do
          expect(User.find_for_google_mobile_auth(google_id_token: "token")).to be_nil
        end
      end
    end

    context "when the audience does not match the client_id" do
      let(:payload) { { "aud" => "different_client_id", "email" => user.email } }

      it "returns nil" do
        expect(User.find_for_google_mobile_auth(google_id_token: "token")).to be_nil
      end
    end

    context "when the token is invalid" do
      before do
        allow(verifier).to receive(:verify).and_raise(Google::Auth::IDTokens::ExpiredTokenError)
      end

      it "returns nil" do
        expect(User.find_for_google_mobile_auth(google_id_token: "token")).to be_nil
      end
    end
  end
end
