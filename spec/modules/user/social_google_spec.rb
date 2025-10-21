# frozen_string_literal: true

require "spec_helper"

describe User::SocialGoogle do
  before(:all) do
    @data = JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/google_omniauth.json").read)
  end

  describe ".find_or_create_for_google_oauth2" do
    before do
      @dataCopy1 = @data.deep_dup
      @dataCopy1["uid"] = "12345"
      @dataCopy1["info"]["email"] = "paulius@example.com"
      @dataCopy1["extra"]["raw_info"]["email"] = "paulius@example.com"

      @dataCopy2 = @data.deep_dup
      @dataCopy2["uid"] = "111111"
      @dataCopy2["info"]["email"] = "spongebob@example.com"
      @dataCopy2["extra"]["raw_info"]["email"] = "spongebob@example.com"
    end

    it "creates a new user if one does not exist with the corresponding google uid or email" do
      User.find_or_create_for_google_oauth2(@data)

      expect(User.find_by(email: @data["info"]["email"])).to_not eq(nil)
      expect(User.find_by(google_uid: @data["uid"])).to_not eq(nil)
    end

    it "finds a user using google's uid payload" do
      createdUser = create(:user, google_uid: @dataCopy1["uid"])
      foundUser = User.find_or_create_for_google_oauth2(@dataCopy1)

      expect(foundUser.id).to eq(createdUser.id)
      expect(createdUser.reload.email).to eq(foundUser.email)
      expect(createdUser.reload.email).to eq(@dataCopy1["info"]["email"])
    end

    it "finds a user using email when google's uid is missing and fills in uid" do
      createdUser = create(:user, email: @dataCopy2["info"]["email"])
      foundUser = User.find_or_create_for_google_oauth2(@dataCopy2)

      expect(createdUser.google_uid).to eq(nil)
      expect(createdUser.reload.google_uid).to eq(foundUser.google_uid)
      expect(createdUser.reload.google_uid).to eq(@dataCopy2["uid"])
    end
  end

  describe ".google_picture_url", :vcr do
    before do
      @user = create(:user, google_uid: @data["uid"])
    end

    it "stores the user's profile picture from Google to S3 and returns the URL for the saved file" do
      google_picture_url = @user.google_picture_url(@data)

      expect(google_picture_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")

      picture_response = HTTParty.get(google_picture_url)
      expect(picture_response.content_type).to eq("image/jpeg")
      expect(picture_response.success?).to eq(true)
    end
  end

  describe ".query_google" do
    describe "email change" do
      it "sets email if the email coming from google is different" do
        @user = create(:user, email: "spongebob@example.com")

        expect { User.query_google(@user, @data) }.to change { @user.reload.email }.from("spongebob@example.com").to(@data["info"]["email"])
      end

      context "when the email already exists in a different case" do
        before do
          @user = create(:user, email: @data["info"]["email"].upcase)
        end

        it "doesn't update email" do
          expect { User.query_google(@user, @data) }.not_to change { @user.reload.email }
        end

        it "doesn't raise error" do
          expect { User.query_google(@user, @data) }.not_to raise_error(ActiveRecord::RecordInvalid)
        end
      end
    end

    describe "already has name" do
      it "does not not set a name if one already exists" do
        @user = create(:user, name: "Spongebob")
        expect { User.query_google(@user, @data) }.to_not change { @user.reload.name }
      end
    end

    describe "no existing information" do
      before do
        @user = create(:user)
      end

      it "sets the google uid if one does not exist upon creation" do
        expect { User.query_google(@user, @data) }.to change { @user.reload.google_uid }.from(nil).to(@data["uid"])
      end

      it "sets the name if one does not exist upon creation" do
        expect { User.query_google(@user, @data) }.to change { @user.reload.name }.from(nil).to(@data["info"]["name"])
      end
    end
  end
end
