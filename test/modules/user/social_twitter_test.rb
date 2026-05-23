# frozen_string_literal: true

require "test_helper"

class UserSocialTwitterTest < ActiveSupport::TestCase
  self.described_class = User::SocialTwitter



  context_ User::SocialTwitter do
  context_ "#twitter_picture_url", :vcr do
      before do
        data = JSON.parse(File.open("#{Rails.root}/test/support/fixtures/twitter_omniauth.json").read)["extra"]["raw_info"]
        @user = create(:user, twitter_user_id: data["id"])
      end

  test "stores the user's profile picture from twitter to S3 and returns the URL for the saved file" do
        twitter_user = double(profile_image_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/kFDzu.png")
        expect($twitter).to receive(:user).and_return(twitter_user)

        twitter_picture_url = @user.twitter_picture_url
        expect(twitter_picture_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")

        picture_response = HTTParty.get(twitter_picture_url)
        expect(picture_response.content_type).to eq("image/png")
        expect(picture_response.success?).to eq(true)
      end
    end

  context_ "query_twitter" do
      before(:all) do
        @data = JSON.parse(File.open("#{Rails.root}/test/support/fixtures/twitter_omniauth.json").read)["extra"]["raw_info"]
      end

  context_ "already has username" do
  test "does not set username", :vcr do
          @user = create(:user, username: "squid")
          expect { User.query_twitter(@user, @data) }.not_to change { @user.reload.username }
        end
      end

  context_ "already has bio" do
  test "does not set bio", :vcr do
          @user = create(:user, bio: "hi im squid")
          expect { User.query_twitter(@user, @data) }.not_to change { @user.reload.bio }
        end
      end

  context_ "already has name" do
  test "does not set bio", :vcr do
          @user = create(:user, name: "sid")
          expect { User.query_twitter(@user, @data) }.not_to change { @user.reload.name }
        end
      end

  context_ "no existing information" do
        before do
          @user = create(:user, name: nil, username: nil, bio: nil)
        end

  test "sets the username", :vcr do
          expect { User.query_twitter(@user, @data) }.to change { @user.reload.username }.to(@data["screen_name"])
        end

  test "sets the bio", :vcr do
          expect { User.query_twitter(@user, @data) }.to change { @user.reload.bio }.from(nil).to(
            "formerly @columbia, now @gumroad gumroad.com"
          )
        end

  test "sets the name", :vcr do
          expect { User.query_twitter(@user, @data) }.to change { @user.reload.name }.from(nil).to(@data["name"])
        end
      end
    end
  end
end
