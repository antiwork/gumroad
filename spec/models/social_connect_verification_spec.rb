# frozen_string_literal: true

require "spec_helper"

describe SocialConnectVerification do
  describe "validations" do
    it "requires a supported platform" do
      verification = build(:social_connect_verification, platform: "myspace")
      expect(verification).not_to be_valid
      expect(verification.errors[:platform]).to be_present
    end

    it "allows one record per platform per user" do
      user = create(:user)
      create(:social_connect_verification, user:, platform: "twitter", uid: "1")
      duplicate = build(:social_connect_verification, user:, platform: "twitter", uid: "2")
      expect(duplicate).not_to be_valid
    end

    it "allows the same social identity across different users" do
      first = create(:social_connect_verification, platform: "twitter", uid: "shared")
      second = build(:social_connect_verification, platform: "twitter", uid: "shared")
      expect(second).to be_valid
      expect(first).to be_valid
    end
  end

  describe "#shared_identity_user_ids" do
    it "returns other users vouched for by the same social identity" do
      shared = create(:social_connect_verification, platform: "twitter", uid: "shared")
      other = create(:social_connect_verification, platform: "twitter", uid: "shared")
      create(:social_connect_verification, platform: "twitter", uid: "different")

      expect(shared.shared_identity_user_ids).to eq([other.user_id])
    end
  end

  describe ".record_from_twitter!" do
    let(:user) { create(:user) }
    let(:raw_info) { JSON.parse(File.read("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json"))["extra"]["raw_info"] }

    it "stores verified profile metadata from the OAuth payload" do
      verification = described_class.record_from_twitter!(user, raw_info)

      expect(verification.reload).to have_attributes(
        platform: "twitter",
        uid: "279418691",
        handle: "squidarth",
        follower_count: 183,
        post_count: 170,
      )
      expect(verification.account_created_at).to eq(DateTime.parse("2011-04-09 06:50:16 UTC"))
      expect(verification.last_posted_at).to eq(DateTime.parse("2013-03-06 23:21:06 UTC"))
      expect(verification.last_verified_at).to be_present
    end

    it "updates the existing record on re-verify instead of creating a second one" do
      described_class.record_from_twitter!(user, raw_info)
      expect do
        described_class.record_from_twitter!(user, raw_info.merge("followers_count" => 500))
      end.not_to change { described_class.count }
      expect(user.social_connect_verifications.sole.follower_count).to eq(500)
    end

    it "records nothing when the payload carries errors" do
      expect do
        described_class.record_from_twitter!(user, raw_info.merge("errors" => [{ "message" => "nope" }]))
      end.not_to change { described_class.count }
    end

    it "records nothing when the uid is missing" do
      expect do
        described_class.record_from_twitter!(user, raw_info.except("id"))
      end.not_to change { described_class.count }
    end

    it "tolerates unparseable timestamps" do
      verification = described_class.record_from_twitter!(user, raw_info.merge("created_at" => "not a date"))
      expect(verification.account_created_at).to be_nil
    end
  end

  describe ".record_from_youtube!" do
    let(:user) { create(:user) }
    let(:channel) do
      {
        "id" => "UC_x5XG1OV2P6uZZ5FSM9Ttw",
        "handle" => "googledevelopers",
        "published_at" => "2007-08-23T00:34:43Z",
        "subscriber_count" => "2400000",
        "video_count" => "5800",
        "last_posted_at" => Time.iso8601("2026-08-01T12:00:00Z"),
      }
    end

    it "stores verified channel metadata" do
      verification = described_class.record_from_youtube!(user, channel)

      expect(verification.reload).to have_attributes(
        platform: "youtube",
        uid: "UC_x5XG1OV2P6uZZ5FSM9Ttw",
        handle: "googledevelopers",
        follower_count: 2_400_000,
        post_count: 5_800,
      )
      expect(verification.account_created_at).to eq(Time.iso8601("2007-08-23T00:34:43Z"))
      expect(verification.last_posted_at).to eq(Time.iso8601("2026-08-01T12:00:00Z"))
    end

    it "records nothing when the channel id is missing" do
      expect do
        described_class.record_from_youtube!(user, channel.merge("id" => ""))
      end.not_to change { described_class.count }
    end
  end

  describe ".record_from_instagram!" do
    let(:user) { create(:user) }
    let(:profile) do
      {
        "user_id" => "17841400000000000",
        "username" => "gumroad",
        "followers_count" => 250_000,
        "media_count" => 1_200,
        "last_posted_at" => "2026-09-01T12:00:00Z",
      }
    end

    it "stores verified professional-account metadata" do
      verification = described_class.record_from_instagram!(user, profile)

      expect(verification.reload).to have_attributes(
        platform: "instagram",
        uid: "17841400000000000",
        handle: "gumroad",
        account_created_at: nil,
        follower_count: 250_000,
        post_count: 1_200,
        last_posted_at: Time.iso8601("2026-09-01T12:00:00Z"),
      )
    end

    it "prefers the app-scoped token user id so deauthorize callbacks can match" do
      verification = described_class.record_from_instagram!(user, profile.merge("token_user_id" => "998877"))

      expect(verification.reload.uid).to eq("998877")
    end

    it "records nothing when the user id is missing" do
      expect do
        described_class.record_from_instagram!(user, profile.except("user_id"))
      end.not_to change { described_class.count }
    end
  end
end
