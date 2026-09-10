# frozen_string_literal: true

require "spec_helper"

describe SocialConnectVerification do
  describe "#currently_linked?" do
    %w[twitter youtube instagram tiktok].each do |platform|
      it "requires the matching current #{platform} UID" do
        user = create(:user)
        verification = create(:social_connect_verification, user:, platform:, uid: "123")
        expect(verification.currently_linked?).to be(false)

        case platform
        when "twitter"
          user.update!(twitter_user_id: "123")
        when "youtube"
          create(:user_youtube_identity, user:, channel_id: "123")
        when "instagram"
          create(:user_instagram_identity, user:, instagram_user_id: "123")
        when "tiktok"
          create(:user_tiktok_identity, user:, tiktok_open_id: "123")
        end
        verification.reload
        expect(verification.currently_linked?).to be(true)

        verification.uid = "456"
        expect(verification.currently_linked?).to be(false)
        verification.uid = nil
        expect(verification.currently_linked?).to be(false)
        verification.uid = "123"

        case platform
        when "twitter"
          verification.user.update!(twitter_user_id: "")
        when "youtube"
          verification.user.youtube_identity.update_columns(channel_id: "")
        when "instagram"
          verification.user.instagram_identity.update_columns(instagram_user_id: "")
        when "tiktok"
          verification.user.tiktok_identity.update_columns(tiktok_open_id: "")
        end
        expect(verification.currently_linked?).to be(false)
        verification.uid = ""
        expect(verification.currently_linked?).to be(false)
      end
    end

    it "does not consider a superseded row linked even when its uid still matches the live identity" do
      verification = create(:social_connect_verification, platform: "twitter", uid: "123", superseded_at: 1.day.ago)
      verification.user.update!(twitter_user_id: "123")

      expect(verification.currently_linked?).to be(false)
    end

    it "does not consider an unknown platform linked" do
      verification = build(:social_connect_verification, platform: "myspace")
      allow(verification).to receive(:platform).and_return("myspace")

      expect(verification.currently_linked?).to be(false)
    end
  end

  describe "validations" do
    it "requires a supported platform" do
      verification = build(:social_connect_verification, platform: "myspace")
      expect(verification).not_to be_valid
      expect(verification.errors[:platform]).to be_present
    end

    it "allows one current record per platform per user" do
      user = create(:user)
      create(:social_connect_verification, user:, platform: "twitter", uid: "1")
      duplicate = build(:social_connect_verification, user:, platform: "twitter", uid: "2")
      expect(duplicate).not_to be_valid
    end

    it "allows superseded records alongside the current one for the same platform" do
      user = create(:user)
      create(:social_connect_verification, user:, platform: "twitter", uid: "1", superseded_at: 2.days.ago)
      current = create(:social_connect_verification, user:, platform: "twitter", uid: "2")
      later_superseded = build(:social_connect_verification, user:, platform: "twitter", uid: "3", superseded_at: 1.day.ago)

      expect(current).to be_valid
      expect(later_superseded).to be_valid
    end

    it "allows the same social identity across different users" do
      first = create(:social_connect_verification, platform: "twitter", uid: "shared")
      second = build(:social_connect_verification, platform: "twitter", uid: "shared")
      expect(second).to be_valid
      expect(first).to be_valid
    end
  end

  describe "#supersede!" do
    it "stamps superseded_at once and leaves an existing stamp alone" do
      verification = create(:social_connect_verification)

      verification.supersede!
      expect(verification.superseded_at).to be_present
      expect(described_class.current).not_to include(verification)

      expect { verification.supersede! }.not_to change { verification.reload.superseded_at }
    end
  end

  describe "#shared_identity_user_ids" do
    it "returns other users vouched for by the same social identity" do
      shared = create(:social_connect_verification, platform: "twitter", uid: "shared")
      other = create(:social_connect_verification, platform: "twitter", uid: "shared")
      create(:social_connect_verification, platform: "twitter", uid: "different")

      expect(shared.shared_identity_user_ids).to eq([other.user_id])
    end

    it "counts superseded identities in both directions" do
      superseded = create(:social_connect_verification, platform: "twitter", uid: "shared", superseded_at: 1.day.ago)
      current = create(:social_connect_verification, platform: "twitter", uid: "shared")

      expect(superseded.shared_identity_user_ids).to eq([current.user_id])
      expect(current.shared_identity_user_ids).to eq([superseded.user_id])
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
      expect(Event.where(event_name: "social_connect_connected", user_id: user.id).count).to eq(1)
    end

    it "skips funnel connected when record_funnel_connected is false" do
      expect do
        described_class.record_from_twitter!(user, raw_info, record_funnel_connected: false)
      end.not_to change { Event.where(event_name: "social_connect_connected").count }

      expect(user.social_connect_verifications.current.sole.uid).to eq("279418691")
    end

    it "updates the existing record on re-verify instead of creating a second one" do
      described_class.record_from_twitter!(user, raw_info)
      expect do
        described_class.record_from_twitter!(user, raw_info.merge("followers_count" => 500))
      end.not_to change { described_class.count }
      expect(user.social_connect_verifications.sole.follower_count).to eq(500)
    end

    it "supersedes the previous identity when a different account is connected" do
      original = described_class.record_from_twitter!(user, raw_info)

      expect do
        described_class.record_from_twitter!(user, raw_info.merge("id" => 999, "screen_name" => "fresh"))
      end.to change { described_class.count }.by(1)

      expect(original.reload).to have_attributes(uid: "279418691", handle: "squidarth", superseded_at: be_present)
      expect(user.social_connect_verifications.current.sole).to have_attributes(uid: "999", handle: "fresh")
    end

    it "revives a previously verified identity instead of duplicating it" do
      original = described_class.record_from_twitter!(user, raw_info)
      replacement = described_class.record_from_twitter!(user, raw_info.merge("id" => 999))

      expect do
        described_class.record_from_twitter!(user, raw_info.merge("followers_count" => 500))
      end.not_to change { described_class.count }

      expect(original.reload).to have_attributes(superseded_at: nil, follower_count: 500)
      expect(replacement.reload.superseded_at).to be_present
      expect(user.social_connect_verifications.current.sole).to eq(original)
    end

    it "revives a soft-superseded identity when no current row remains" do
      original = described_class.record_from_twitter!(user, raw_info)
      original.supersede!
      expect(described_class.current.where(user:, platform: "twitter")).to be_empty

      expect do
        described_class.record_from_twitter!(user, raw_info.merge("followers_count" => 600))
      end.not_to change { described_class.count }

      expect(original.reload).to have_attributes(superseded_at: nil, follower_count: 600, uid: "279418691")
      expect(user.social_connect_verifications.current.sole).to eq(original)
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

    it "supersedes the previous channel when a different one is connected" do
      original = described_class.record_from_youtube!(user, channel)

      expect do
        described_class.record_from_youtube!(user, channel.merge("id" => "UCother"))
      end.to change { described_class.count }.by(1)

      expect(original.reload).to have_attributes(uid: "UC_x5XG1OV2P6uZZ5FSM9Ttw", superseded_at: be_present)
      expect(user.social_connect_verifications.current.sole.uid).to eq("UCother")
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

    it "supersedes the previous account when a different one is connected" do
      original = described_class.record_from_instagram!(user, profile)

      expect do
        described_class.record_from_instagram!(user, profile.merge("user_id" => "998877"))
      end.to change { described_class.count }.by(1)

      expect(original.reload).to have_attributes(uid: "17841400000000000", superseded_at: be_present)
      expect(user.social_connect_verifications.current.sole.uid).to eq("998877")
    end

    it "records nothing when the user id is missing" do
      expect do
        described_class.record_from_instagram!(user, profile.except("user_id"))
      end.not_to change { described_class.count }
    end
  end

  describe ".record_from_tiktok!" do
    let(:user) { create(:user) }
    let(:profile) do
      {
        "open_id" => "open-123",
        "username" => "gumroad",
        "display_name" => "Gumroad",
        "profile_web_link" => "https://www.tiktok.com/@gumroad",
        "follower_count" => 250_000,
        "video_count" => 1_200,
      }
    end

    it "stores verified metadata and leaves TikTok-unsupported dates unknown" do
      verification = described_class.record_from_tiktok!(user, profile)

      expect(verification.reload).to have_attributes(
        platform: "tiktok",
        uid: "open-123",
        handle: "gumroad",
        account_created_at: nil,
        follower_count: 250_000,
        post_count: 1_200,
        last_posted_at: nil,
      )
    end

    it "stores missing counts as unknown rather than zero" do
      verification = described_class.record_from_tiktok!(user, profile.merge("follower_count" => nil, "video_count" => ""))

      expect(verification.reload).to have_attributes(follower_count: nil, post_count: nil)
    end

    it "keeps a real zero count" do
      verification = described_class.record_from_tiktok!(user, profile.merge("follower_count" => 0, "video_count" => 0))

      expect(verification.reload).to have_attributes(follower_count: 0, post_count: 0)
    end

    it "falls back to the profile link handle then display name" do
      without_username = described_class.record_from_tiktok!(user, profile.except("username"))
      expect(without_username.handle).to eq("gumroad")

      without_username.supersede!
      display_only = described_class.record_from_tiktok!(user, profile.except("username", "profile_web_link"))
      expect(display_only.handle).to eq("Gumroad")
    end

    it "records nothing when open_id is missing" do
      expect do
        described_class.record_from_tiktok!(user, profile.except("open_id"))
      end.not_to change { described_class.count }
    end
  end
end
