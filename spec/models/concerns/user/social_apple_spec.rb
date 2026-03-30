# frozen_string_literal: true

require "spec_helper"

describe User::SocialApple do
  let(:user) { create(:user) }

  describe ".find_or_create_for_apple_oauth" do
    let(:apple_uid) { "001234.abcdef1234567890abcdef1234567890.1234" }
    let(:apple_data) do
      {
        "uid" => apple_uid,
        "info" => {
          "email" => "apple-user@example.com",
          "name" => "Jane Appleseed"
        }
      }
    end

    context "when no matching user exists" do
      it "creates a new user with an external authentication" do
        expect { User.find_or_create_for_apple_oauth(apple_data) }.to change { User.count }.by(1)

        created_user = User.last
        expect(created_user.user_external_authentications.find_by(provider: "apple")&.uid).to eq(apple_uid)
        expect(created_user.email).to eq("apple-user@example.com")
        expect(created_user.name).to eq("Jane Appleseed")
        expect(created_user.provider).to eq("apple")
        expect(created_user.confirmed?).to be true
      end

      it "attaches past purchases with the same email" do
        purchase = create(:purchase, email: "apple-user@example.com")
        expect(purchase.purchaser_id).to be_nil

        User.find_or_create_for_apple_oauth(apple_data)

        created_user = User.last
        expect(purchase.reload.purchaser_id).to eq(created_user.id)
      end
    end

    context "when a user with the same apple uid exists" do
      let!(:existing_user) { create(:user) }

      before do
        UserExternalAuthentication.create!(user: existing_user, provider: "apple", uid: apple_uid)
      end

      it "returns the existing user without creating a new one" do
        expect { User.find_or_create_for_apple_oauth(apple_data) }.not_to change { User.count }

        result = User.find_or_create_for_apple_oauth(apple_data)
        expect(result).to eq(existing_user)
      end
    end

    context "when a user with the same email exists" do
      let!(:existing_user) { create(:user, email: "apple-user@example.com") }

      it "links the apple authentication to the existing user" do
        result = User.find_or_create_for_apple_oauth(apple_data)

        expect(result).to eq(existing_user)
        expect(existing_user.user_external_authentications.find_by(provider: "apple")&.uid).to eq(apple_uid)
      end

      it "does not create a new user" do
        expect { User.find_or_create_for_apple_oauth(apple_data) }.not_to change { User.count }
      end
    end

    context "when the uid is blank" do
      it "returns nil and notifies error tracker" do
        expect(ErrorNotifier).to receive(:notify).with("Apple OAuth data is missing a uid")

        result = User.find_or_create_for_apple_oauth({ "uid" => "", "info" => {} })
        expect(result).to be_nil
      end
    end

    context "when name is nil" do
      it "creates a user without a name" do
        data = apple_data.merge("info" => { "email" => "apple-user@example.com", "name" => nil })

        User.find_or_create_for_apple_oauth(data)

        created_user = User.last
        expect(created_user.name).to be_blank
      end
    end

    context "when name is already set on existing user" do
      let!(:existing_user) { create(:user, email: "apple-user@example.com", name: "Existing Name") }

      it "does not overwrite the existing name" do
        User.find_or_create_for_apple_oauth(apple_data)

        expect(existing_user.reload.name).to eq("Existing Name")
      end
    end
  end

  describe ".find_for_apple_auth" do
    let(:id_token_double) { double(verify!: double, email_verified?: true, email: user.email) }
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
