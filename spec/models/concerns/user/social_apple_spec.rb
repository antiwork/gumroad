# frozen_string_literal: true

require "spec_helper"

describe User::SocialApple do
  let(:user) { create(:user) }
  let(:id_token_double) { double(verify!: double, email_verified?: true, email: user.email) }

  describe ".find_for_apple_auth" do
    before do
      @apple_id_client = double("apple_id_client")
      allow(@apple_id_client).to receive(:authorization_code=)
      allow(AppleID::Client).to receive(:new).and_return(@apple_id_client)

      @access_token_double = double("access token")
      token_response_double = double(id_token: id_token_double, access_token: @access_token_double)
      allow(@apple_id_client).to receive(:access_token!).and_return(token_response_double)
    end

    shared_examples_for "finds user using Apple's authorization_code" do |app_type|
      context "when the email is verified" do
        it "finds the user using Apple authorization code" do
          expect(id_token_double).to receive(:verify!) do |options|
            expect(options[:client]).to eq @apple_id_client
            expect(options[:access_token]).to eq @access_token_double
            expect(options[:verify_signature]).to eq false
          end

          fetched_user = User.find_for_apple_auth(authorization_code: "auth_code", app_type:)
          expect(fetched_user).to eq user
        end
      end

      context "when the email is not verified" do
        let(:id_token_double) { double(verify!: double, email_verified?: false, email: user.email) }

        it "doesn't return the user" do
          fetched_user = User.find_for_apple_auth(authorization_code: "auth_code", app_type:)
          expect(fetched_user).to be_nil
        end
      end
    end

    context "when the request is from consumer app" do
      it "initializes AppleID client using consumer app credentials" do
        expect(AppleID::Client).to receive(:new) do |options|
          expect(options[:identifier]).to eq GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_IDENTIFIER")
          expect(options[:team_id]).to eq GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_TEAM_ID")
          expect(options[:key_id]).to eq GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_KEY_ID")
          expect(options[:private_key]).to be_a(OpenSSL::PKey::EC)
        end.and_return(@apple_id_client)

        User.find_for_apple_auth(authorization_code: "auth_code", app_type: "consumer")
      end

      it_behaves_like "finds user using Apple's authorization_code", "consumer"
    end

    context "when the request is from creator app" do
      it "initializes AppleID client using creator app credentials" do
        expect(AppleID::Client).to receive(:new) do |options|
          expect(options[:identifier]).to eq GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_IDENTIFIER")
          expect(options[:team_id]).to eq GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_TEAM_ID")
          expect(options[:key_id]).to eq GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_KEY_ID")
          expect(options[:private_key]).to be_a(OpenSSL::PKey::EC)
        end.and_return(@apple_id_client)

        User.find_for_apple_auth(authorization_code: "auth_code", app_type: "creator")
      end

      it_behaves_like "finds user using Apple's authorization_code", "creator"
    end
  end
end
