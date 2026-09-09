# frozen_string_literal: true

class SocialConnectVerification < ApplicationRecord
  PLATFORMS = %w[twitter youtube instagram tiktok].freeze

  belongs_to :user

  validates :platform, presence: true, inclusion: { in: PLATFORMS }
  validates :uid, presence: true
  validates :last_verified_at, presence: true
  # Superseded rows are kept as veto evidence, so only the live row per platform is unique.
  validates :platform, uniqueness: { scope: :user_id, conditions: -> { current } }, unless: :superseded?

  scope :current, -> { where(superseded_at: nil) }

  def superseded?
    superseded_at.present?
  end

  def supersede!
    return if superseded?

    update!(superseded_at: Time.current)
  end

  # Unlinking clears the user's twitter columns but keeps the verification row as evidence,
  # so the row alone cannot tell a reviewer whether the connection is still live.
  def currently_linked?
    return false if superseded?

    case platform
    when "twitter"
      user.twitter_user_id.present? && user.twitter_user_id.to_s == uid.to_s
    when "youtube"
      channel_id = user.youtube_identity&.channel_id
      channel_id.present? && channel_id.to_s == uid.to_s
    when "instagram"
      instagram_user_id = user.instagram_identity&.instagram_user_id
      instagram_user_id.present? && instagram_user_id.to_s == uid.to_s
    when "tiktok"
      tiktok_open_id = user.tiktok_identity&.tiktok_open_id
      tiktok_open_id.present? && tiktok_open_id.to_s == uid.to_s
    else
      false
    end
  end

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

    record!(
      user, "twitter", uid,
      handle: raw_info["screen_name"],
      account_created_at: parse_twitter_time(raw_info["created_at"]),
      follower_count: raw_info["followers_count"],
      post_count: raw_info["statuses_count"],
      last_posted_at: parse_twitter_time(raw_info.dig("status", "created_at")),
    )
  end

  # YouTube Data API channel payload from YoutubeChannelFetcher.
  def self.record_from_youtube!(user, channel)
    uid = channel["id"].to_s
    return if uid.blank?

    record!(
      user, "youtube", uid,
      handle: channel["handle"],
      account_created_at: parse_iso8601(channel["published_at"]),
      follower_count: channel["subscriber_count"].presence&.to_i,
      post_count: channel["video_count"].presence&.to_i,
      last_posted_at: channel["last_posted_at"].is_a?(Time) ? channel["last_posted_at"] : parse_iso8601(channel["last_posted_at"]),
    )
  end

  def self.record_from_tiktok!(user, profile)
    uid = profile["open_id"].to_s
    return if uid.blank?

    record!(
      user, "tiktok", uid,
      handle: tiktok_handle(profile),
      account_created_at: nil,
      follower_count: int_or_unknown(profile["follower_count"]),
      post_count: int_or_unknown(profile["video_count"]),
      last_posted_at: nil,
    )
  end

  def self.record_from_instagram!(user, profile)
    # Meta's deauthorize/data-deletion signed_request carries the app-scoped
    # (token) user id, so that must be the canonical uid or those callbacks
    # delete nothing.
    uid = (profile["token_user_id"].presence || profile["user_id"].presence || profile["id"]).to_s
    return if uid.blank?

    record!(
      user, "instagram", uid,
      handle: profile["username"],
      account_created_at: nil,
      follower_count: profile["followers_count"].presence&.to_i,
      post_count: profile["media_count"].presence&.to_i,
      last_posted_at: parse_iso8601(profile["last_posted_at"]),
    )
  end

  # Same identity refreshes in place; a different one supersedes so the old
  # uid keeps vetoing. After soft-supersede, reconnect revives the matching
  # prior row to avoid unique [user, platform, uid].
  def self.record!(user, platform, uid, **attributes)
    transaction do
      # Lock a fresh User: callers often pass a dirty User (with_lock raises),
      # and [user_id, platform] is no longer uniquely one current row.
      User.lock.find(user.id)
      verification = current.find_or_initialize_by(user:, platform:)
      if verification.persisted? && verification.uid != uid
        verification.supersede!
        verification = find_or_initialize_by(user:, platform:, uid:)
      elsif !verification.persisted?
        verification = find_or_initialize_by(user:, platform:, uid:)
      end
      verification.update!(uid:, superseded_at: nil, last_verified_at: Time.current, **attributes)
      verification
    end
  end
  private_class_method :record!

  def self.tiktok_handle(profile)
    profile["username"].presence ||
      profile["profile_web_link"].to_s[%r{@([^/?#]+)}, 1].presence ||
      profile["display_name"].presence
  end
  private_class_method :tiktok_handle

  def self.int_or_unknown(value)
    return if value.nil? || (value.is_a?(String) && value.strip.empty?)

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :int_or_unknown

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
