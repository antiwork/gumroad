# frozen_string_literal: true

class SocialConnectVerification < ApplicationRecord
  PLATFORMS = %w[twitter youtube instagram tiktok].freeze

  belongs_to :user

  validates :platform, presence: true, inclusion: { in: PLATFORMS }
  validates :uid, presence: true
  validates :last_verified_at, presence: true
  validates :platform, uniqueness: { scope: :user_id }

  # Other Gumroad accounts vouched for by the same social identity — the
  # dedupe signal risk reviewers check (same precedent as bank/card fingerprints).
  def shared_identity_user_ids
    self.class.where(platform:, uid:).where.not(user_id:).pluck(:user_id)
  end

  # Twitter's OAuth 1.0a raw_info payload, from both the signup and the
  # link-account callback paths.
  def self.record_from_twitter!(user, raw_info)
    uid = raw_info["id"].to_s
    return if uid.blank? || raw_info["errors"].present?

    verification = find_or_initialize_by(user:, platform: "twitter")
    verification.update!(
      uid:,
      handle: raw_info["screen_name"],
      account_created_at: parse_twitter_time(raw_info["created_at"]),
      follower_count: raw_info["followers_count"],
      post_count: raw_info["statuses_count"],
      last_posted_at: parse_twitter_time(raw_info.dig("status", "created_at")),
      last_verified_at: Time.current,
    )
    verification
  end

  # YouTube Data API channel payload from YoutubeChannelFetcher.
  def self.record_from_youtube!(user, channel)
    uid = channel["id"].to_s
    return if uid.blank?

    verification = find_or_initialize_by(user:, platform: "youtube")
    verification.update!(
      uid:,
      handle: channel["handle"],
      account_created_at: parse_iso8601(channel["published_at"]),
      follower_count: channel["subscriber_count"].presence&.to_i,
      post_count: channel["video_count"].presence&.to_i,
      last_posted_at: channel["last_posted_at"].is_a?(Time) ? channel["last_posted_at"] : parse_iso8601(channel["last_posted_at"]),
      last_verified_at: Time.current,
    )
    verification
  end

  def self.record_from_instagram!(user, profile)
    uid = (profile["user_id"].presence || profile["id"]).to_s
    return if uid.blank?

    verification = find_or_initialize_by(user:, platform: "instagram")
    verification.update!(
      uid:,
      handle: profile["username"],
      account_created_at: nil,
      follower_count: profile["followers_count"].presence&.to_i,
      post_count: profile["media_count"].presence&.to_i,
      last_posted_at: parse_iso8601(profile["last_posted_at"]),
      last_verified_at: Time.current,
    )
    verification
  end

  def self.parse_twitter_time(value)
    return if value.blank?

    # Twitter's legacy format: "Sat Mar 21 16:47:01 +0000 2015"
    DateTime.strptime(value, "%a %b %d %H:%M:%S %z %Y")
  rescue Date::Error
    nil
  end
  private_class_method :parse_twitter_time

  def self.parse_iso8601(value)
    return if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
  private_class_method :parse_iso8601
end
