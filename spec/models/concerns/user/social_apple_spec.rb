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

      it "drops the password the signup never proved when the account is unconfirmed", :aggregate_failures do
        password_set_at_signup = "chosen-by-whoever-signed-up"
        unconfirmed_user = create(:unconfirmed_user, email: "apple-unconfirmed@example.com", password: password_set_at_signup)
        data = apple_data.merge("uid" => "001234.apple-unconfirmed", "info" => { "email" => "apple-unconfirmed@example.com" })

        result = User.find_or_create_for_apple_oauth(data)

        expect(result.id).to eq(unconfirmed_user.id)
        expect(unconfirmed_user.reload).to be_confirmed
        expect(unconfirmed_user.valid_password?(password_set_at_signup)).to be(false)
      end

      it "keeps the password of an account that already confirmed its email" do
        password_set_by_its_owner = "chosen-by-its-owner"
        confirmed_user = create(:user, email: "apple-confirmed@example.com", password: password_set_by_its_owner)
        data = apple_data.merge("uid" => "001234.apple-confirmed", "info" => { "email" => "apple-confirmed@example.com" })

        User.find_or_create_for_apple_oauth(data)

        expect(confirmed_user.reload.valid_password?(password_set_by_its_owner)).to be(true)
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
