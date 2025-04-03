# frozen_string_literal: true

module User::SocialTwitter
  TWITTER_PROPERTIES = %w[twitter_user_id twitter_handle twitter_oauth_token twitter_oauth_secret].freeze

  def self.included(base)
    base.extend(TwitterClassMethods)
  end

  def twitter_picture_url
    twitter_user = $twitter.user(twitter_user_id.to_i)
    pic_url = twitter_user.profile_image_url.to_s.gsub("_normal.", "_400x400.")
    pic_url = URI(URI::DEFAULT_PARSER.escape(pic_url))

    URI.open(pic_url) do |remote_file|
      tempfile = Tempfile.new(binmode: true)
      tempfile.write(remote_file.read)
      tempfile.rewind
      self.avatar.attach(io: tempfile,
                         filename: File.basename(pic_url.to_s),
                         content_type: remote_file.content_type)
      self.avatar.blob.save!
    end

    self.avatar.analyze unless self.avatar.attached?

    self.avatar_url
  rescue StandardError
    nil
  end

  module TwitterClassMethods
    # Find user by Twitter ID, Email or create one.
    def find_or_create_for_twitter_oauth!(data)
      info = data["extra"]["raw_info"]
      user = User.where(twitter_user_id: info["id"]).first

      unless user
        user = User.new
        user.provider = :twitter
        user.twitter_user_id = info["id"]
        user.password = Devise.friendly_token[0, 20]
        user.skip_confirmation!
        user.save!
      end

      if info["errors"].present?
        info["errors"].each do |error|
          logger.error "Error getting extra info from Twitter OAuth: #{error.message}"
        end
      else
        query_twitter(user, info)
      end

      user.save!
      user
    end

    # Save Twitter data in DB
    def query_twitter(user, data)
      return unless user

      # Dont overwrite fields of existing users.
      logger.info(data.inspect)
      user.twitter_user_id = data["id"]
      user.twitter_handle = data["screen_name"]

      # don't set these properties if they already have values
      user.name ||= data["name"]
      data["entities"]["description"]["urls"].each do |url|
        data["description"].gsub!(url["url"], url["display_url"])
      end

      user.bio ||= data["description"]
      user.username = user.twitter_handle unless user.read_attribute(:username).present?
      user.username = nil unless user.valid?
      user.save

      user.twitter_picture_url unless user.avatar.attached?
    end
  end
end
