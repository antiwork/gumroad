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

      it "leaves the password and the sessions alone", :aggregate_failures do
        existing_user.update!(password: "chosen-by-its-owner")

        expect { User.find_or_create_for_apple_oauth(apple_data) }
          .not_to change { existing_user.reload.last_active_sessions_invalidated_at }

        expect(existing_user.reload.valid_password?("chosen-by-its-owner")).to be(true)
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

      it "drops the password the signup never proved and confirms the account", :aggregate_failures do
        password_set_at_signup = "chosen-by-whoever-signed-up"
        unconfirmed_user = create(:unconfirmed_user, email: "apple-unconfirmed@example.com", password: password_set_at_signup)
        data = apple_data.merge("uid" => "001234.apple-unconfirmed", "info" => { "email" => "apple-unconfirmed@example.com" })

        result = User.find_or_create_for_apple_oauth(data)

        expect(result.id).to eq(unconfirmed_user.id)
        expect(unconfirmed_user.reload).to be_confirmed
        expect(unconfirmed_user.valid_password?(password_set_at_signup)).to be(false)
      end

      it "drops that password when the account had already confirmed its email" do
        password_set_at_signup = "chosen-by-whoever-signed-up"
        confirmed_user = create(:user, email: "apple-confirmed@example.com", password: password_set_at_signup)
        data = apple_data.merge("uid" => "001234.apple-confirmed", "info" => { "email" => "apple-confirmed@example.com" })

        User.find_or_create_for_apple_oauth(data)

        expect(confirmed_user.reload.valid_password?(password_set_at_signup)).to be(false)
      end

      it "revokes every other way in the creator of an unconfirmed account set up and discards its pending email", :aggregate_failures do
        unconfirmed_user = create(:unconfirmed_user, email: "apple-revoke@example.com", password: "chosen-by-whoever-signed-up")
        unconfirmed_user.update!(email: "signup-pending@example.com")
        token = create("doorkeeper/access_token", resource_owner_id: unconfirmed_user.id, scopes: "edit_products")
        unconfirmed_user.webauthn_credentials.create!(webauthn_id: "signup-passkey", public_key: "public-key", sign_count: 0, nickname: "Passkey")
        unconfirmed_user.create_totp_credential!(confirmed_at: Time.current)
        create(:device, user: unconfirmed_user)
        unconfirmed_user.update!(twitter_user_id: "9876543210")
        data = apple_data.merge("uid" => "001234.apple-revoke", "info" => { "email" => "apple-revoke@example.com" })

        expect(User.find_or_create_for_apple_oauth(data)).to eq(unconfirmed_user)

        unconfirmed_user.reload
        expect(unconfirmed_user).to be_confirmed
        expect(unconfirmed_user.email).to eq("apple-revoke@example.com")
        expect(unconfirmed_user.unconfirmed_email).to be_nil
        expect(token.reload).to be_revoked
        expect(unconfirmed_user.webauthn_credentials).to be_empty
        expect(unconfirmed_user.totp_credential).to be_nil
        expect(unconfirmed_user.devices).to be_empty
        expect(unconfirmed_user.twitter_user_id).to be_nil
      end

      it "does not apply a confirmed account's pending email change", :aggregate_failures do
        confirmed_user = create(:user, email: "apple-pending@example.com")
        confirmed_user.update!(email: "owner-pending@example.com")
        data = apple_data.merge("uid" => "001234.apple-pending", "info" => { "email" => "apple-pending@example.com" })

        User.find_or_create_for_apple_oauth(data)

        expect(confirmed_user.reload.email).to eq("apple-pending@example.com")
        expect(confirmed_user.unconfirmed_email).to eq("owner-pending@example.com")
      end

      it "invalidates the sessions the password signup left behind" do
        password_set_at_signup = "chosen-by-whoever-signed-up"
        unconfirmed_user = create(:unconfirmed_user, email: "apple-sessions@example.com", password: password_set_at_signup)
        data = apple_data.merge("uid" => "001234.apple-sessions", "info" => { "email" => "apple-sessions@example.com" })

        expect { User.find_or_create_for_apple_oauth(data) }
          .to change { unconfirmed_user.reload.last_active_sessions_invalidated_at }.from(nil).to(be_present)
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
end
