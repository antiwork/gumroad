# frozen_string_literal: true

require "spec_helper"

describe User::SocialTwitter do
  describe "#twitter_picture_url", :vcr do
    before do
      data = JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json").read)["extra"]["raw_info"]
      @user = create(:user, twitter_user_id: data["id"])
    end

    it "stores the user's profile picture from twitter to S3 and returns the URL for the saved file" do
      twitter_user = double(profile_image_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/kFDzu.png")
      expect($twitter).to receive(:user).and_return(twitter_user)

      twitter_picture_url = @user.twitter_picture_url
      expect(twitter_picture_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")

      picture_response = HTTParty.get(twitter_picture_url)
      expect(picture_response.content_type).to eq("image/png")
      expect(picture_response.success?).to eq(true)
    end
  end

  describe "query_twitter" do
    before(:all) do
      @data = JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json").read)["extra"]["raw_info"]
    end

    describe "already has username" do
      it "does not set username", :vcr do
        @user = create(:user, username: "squid")
        expect { User.query_twitter(@user, @data) }.to_not change { @user.reload.username }
      end
    end

    describe "already has bio" do
      it "does not set bio", :vcr do
        @user = create(:user, bio: "hi im squid")
        expect { User.query_twitter(@user, @data) }.to_not change { @user.reload.bio }
      end
    end

    describe "already has name" do
      it "does not set bio", :vcr do
        @user = create(:user, name: "sid")
        expect { User.query_twitter(@user, @data) }.to_not change { @user.reload.name }
      end
    end

    describe "no existing information" do
      before do
        @user = create(:user, name: nil, username: nil, bio: nil)
      end

      it "sets the username", :vcr do
        expect { User.query_twitter(@user, @data) }.to change { @user.reload.username }.to(@data["screen_name"])
      end

      it "sets the bio", :vcr do
        expect { User.query_twitter(@user, @data) }.to change { @user.reload.bio }.from(nil).to(
          "formerly @columbia, now @gumroad gumroad.com"
        )
      end

      it "sets the name", :vcr do
        expect { User.query_twitter(@user, @data) }.to change { @user.reload.name }.from(nil).to(@data["name"])
      end

      it "sets the name with colons removed", :vcr do
        data_with_colon = @data.deep_dup
        data_with_colon["name"] = "Test: User"

        expect { User.query_twitter(@user, data_with_colon) }.to change { @user.reload.name }.from(nil).to("Test User")
        expect(@user).to be_valid
      end
    end

    describe "social connect verification" do
      before do
        @user = create(:user)
      end

      it "records a verification with the profile metadata", :vcr do
        expect { User.query_twitter(@user, @data) }.to change { @user.social_connect_verifications.count }.by(1)

        verification = @user.social_connect_verifications.sole
        expect(verification).to have_attributes(platform: "twitter", uid: @data["id"].to_s, handle: @data["screen_name"])
        expect(verification.follower_count).to eq(@data["followers_count"])
      end

      it "does not break the connect flow when recording fails", :vcr do
        allow(SocialConnectVerification).to receive(:record_from_twitter!).and_raise(StandardError, "boom")

        expect { User.query_twitter(@user, @data) }.not_to raise_error
        expect(@user.reload.twitter_handle).to eq(@data["screen_name"])
      end

      it "records funnel connected for link-account query_twitter" do
        expect do
          User.query_twitter(@user, @data)
        end.to change { Event.where(event_name: "social_connect_connected", user_id: @user.id).count }.by(1)
      end

      it "does not record funnel connected when login/signup disables it" do
        expect do
          User.query_twitter(@user, @data, record_funnel_connected: false)
        end.not_to change { Event.where(event_name: "social_connect_connected").count }

        expect(@user.social_connect_verifications.count).to eq(1)
      end
    end
  end

  describe ".find_or_create_for_twitter_oauth!" do
    before(:all) do
      @omniauth = JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json").read)
    end

    it "stores verification metadata on login without writing funnel connected" do
      auth = @omniauth.deep_dup
      auth["extra"]["raw_info"]["id"] = rand(1_000_000_000..2_000_000_000)
      auth["extra"]["raw_info"]["screen_name"] = "login_only_#{auth["extra"]["raw_info"]["id"]}"
      allow_any_instance_of(User).to receive(:twitter_picture_url).and_return(nil)

      user = nil
      expect do
        user = User.find_or_create_for_twitter_oauth!(auth)
      end.not_to change { Event.where(event_name: "social_connect_connected").count }

      expect(user.social_connect_verifications.current.sole.platform).to eq("twitter")
      expect(Event.where(event_name: "social_connect_attempted", user_id: user.id)).to be_empty
    end
  end
end
