# frozen_string_literal: true

module User::SocialGoogle
  extend ActiveSupport::Concern

  def google_picture_url(data)
    return nil if data["info"]["image"].nil? || data["info"]["image"].empty?

    pic_url = data["info"]["image"]
    # Replacing all instances of "s96-c" in the string with "s400-c" to get a larger image
    pic_url = pic_url.gsub("s96-c", "s400-c")
    pic_url = URI(URI::DEFAULT_PARSER.escape(pic_url))

    URI.open(pic_url, open_timeout: 5, read_timeout: 5) do |remote_file|
      content_type = remote_file.content_type
      return nil unless valid_avatar_content_type?(content_type)

      tempfile = Tempfile.new(binmode: true)
      tempfile.write(remote_file.read)
      tempfile.rewind

      return nil if tempfile.size > User::Validations::MAXIMUM_AVATAR_FILE_SIZE

      self.avatar.attach(io: tempfile,
                         filename: File.basename(pic_url.to_s),
                         content_type: content_type)
      self.avatar.blob.save!
    end

    self.avatar.analyze unless self.avatar.attached?

    self.avatar_url
  rescue StandardError
    nil
  end

  def valid_avatar_content_type?(content_type)
    return false if content_type.blank?
    User::Validations::ALLOWED_AVATAR_EXTENSIONS.any? { |ext| content_type.include?(ext) }
  end

  class_methods do
    def find_or_create_for_google_oauth2(data)
      retries = 0

      begin
        if data["uid"].blank?
          ErrorNotifier.notify("Google OAuth2 data is missing a uid")
          return nil
        end

        user = User.where(google_uid: data["uid"]).first

        if user.nil?
          email = data["info"]["email"] || data["extra"]["raw_info"]["email"]
          user = User.where(email:).first if EmailFormatValidator.valid?(email)

          if user.nil?
            user = User.new
            user.provider = :google_oauth2
            user.password = Devise.friendly_token[0, 20]
            query_google(user, data, new_user: true)

            if user.email.present?
              Purchase.where(email: user.email, purchaser_id: nil).each do |past_purchase|
                past_purchase.attach_to_user_and_card(user, nil, nil)
              end
            end
          else
            query_google(user, data)
          end
        else
          query_google(user, data)
        end

        user
      rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
        retries += 1
        retry if retries <= 2

        logger.error("Lock error finding or creating user via Google OAuth2 after #{retries} retries: #{e.class} - #{e.message}")
        ErrorNotifier.notify(e)
        nil
      end
    rescue ActiveRecord::RecordInvalid => e
      logger.error("Error finding or creating user via Google OAuth2: #{e.message}")
      ErrorNotifier.notify(e)
      nil
    end

    def query_google(user, data, new_user: false)
      return if data.blank? || data.is_a?(String)

      email = data["info"]["email"] || data["extra"]["raw_info"]["email"]

      # Don't set user properties if they already have values
      user.google_uid ||= data["uid"]

      if user.name.blank? && data["info"]["name"].present?
        sanitized_name = data["info"]["name"].gsub(User::INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX, "")
        user.name = sanitized_name
      end

      # Always update user's email upon log in as it may have changed
      # on google's side
      # https://support.google.com/accounts/answer/19870?hl=en
      if EmailFormatValidator.valid?(email) && user.email&.downcase != email.downcase
        user.email = email
      end

      # Set user's avatar if they don't have one
      user.google_picture_url(data) unless user.avatar.attached?

      user.skip_confirmation_notification!
      user.save!
      user.confirm if user.has_unconfirmed_email?

      user
    end
  end
end
