# frozen_string_literal: true

module User::Validations
  ALLOWED_AVATAR_EXTENSIONS = ["png", "jpg", "jpeg"]
  MINIMUM_AVATAR_DIMENSION = 200
  MAXIMUM_AVATAR_FILE_SIZE = 10.megabytes
  GA_REGEX = %r{G-[a-zA-Z0-9]+} # Regex for Google Analytics 4 Measurement ID.

  private
    def google_analytics_id_valid
      return if google_analytics_id.blank? || google_analytics_id.match(GA_REGEX)

      errors.add(:base, "Please enter a valid Google Analytics ID")
    end

    def email_almost_unique
      return if !email_changed? || email.blank? || User.by_email(email).empty?

      errors.add(:base, "An account already exists with this email.")
    end

    def account_created_email_domain_is_not_blocked
      return if self.errors[:email].present?

      email_domain = Mail::Address.new(email).domain
      return if email_domain.blank?
      return unless BlockedObject.email_domain.find_active_object(email_domain)&.blocked?

      errors.add(:base, "Something went wrong.")
    end

    def account_created_ip_is_not_blocked
      return if account_created_ip.blank?
      return unless BlockedObject.find_active_object(account_created_ip)&.blocked?

      errors.add(:base, "Something went wrong.")
    end

    def avatar_is_valid
      return if !avatar.attached? || !avatar.new_record?

      if avatar.byte_size > MAXIMUM_AVATAR_FILE_SIZE
        errors.add(:base,
                   "Please upload a profile picture with a size smaller than #{ApplicationController.helpers.number_to_human_size(MAXIMUM_AVATAR_FILE_SIZE)}")
        return
      end

      begin
        avatar.analyze if avatar.metadata["height"].blank? || avatar.metadata["width"].blank?
        errors.add(:base, "Please upload a profile picture that is at least 200x200px") if avatar.metadata["height"].to_i < MINIMUM_AVATAR_DIMENSION || avatar.metadata["width"].to_i < MINIMUM_AVATAR_DIMENSION
      rescue ActiveStorage::FileNotFoundError
        # In Rails 6, newly uploaded files are not stored until after validation passes on save (see https://github.com/rails/rails/pull/33303). As a result, we cannot perform this validation unless direct upload is used.
      end

      supported_extensions = ALLOWED_AVATAR_EXTENSIONS.join(", ")
      errors.add(:base, "Please upload a profile picture with one of the following extensions: #{supported_extensions}.") if ALLOWED_AVATAR_EXTENSIONS.none? { |ext| avatar.content_type.to_s.match?(ext) }
    end

    def facebook_meta_tag_is_valid
      return if facebook_meta_tag.blank? || facebook_meta_tag.match?(/\A<meta\s+name=(["'])facebook-domain-verification(?:\1)\s+content=(["'])\w+(?:\2)\s*\/>\z/)

      errors.add(:base, "Please enter a valid meta tag")
    end

    def payout_frequency_is_valid
      return if [User::PayoutSchedule::DAILY, User::PayoutSchedule::WEEKLY, User::PayoutSchedule::MONTHLY, User::PayoutSchedule::QUARTERLY].include?(payout_frequency)

      errors.add(:payout_frequency, "must be daily, weekly, monthly, or quarterly")
    end

  protected
    def json_data_must_be_hash
      raise "json_data must be a hash" unless json_data.is_a?(Hash)
    end
end
