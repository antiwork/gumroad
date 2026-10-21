# frozen_string_literal: true

# Consent for Gumroad feature announcements, separate from `announcement_notification_enabled`.
# No row means not subscribed; an opt-out stays as a `subscribed: false` tombstone so a later
# insert can't resubscribe anyone. `version` lets Settings detect a form rendered before a write.
class FeatureAnnouncementSubscription < ApplicationRecord
  SOURCES = %w[settings unsubscribe_link newsletter_migration newsletter_opt_out legacy_announcements_migration].freeze
  UNSUBSCRIBE_TOKEN_SCOPE = "feature_announcements_unsubscribe"
  LOCK_WAIT_SECONDS = 10

  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }

  def self.subscribed?(user)
    where(user_id: user.id, subscribed: true).exists?
  end

  def self.state_for(user)
    row = find_by(user_id: user.id)
    { subscribed: row&.subscribed || false, version: row&.version || 0 }
  end

  # One atomic statement, so an absent row still ends up as a tombstone.
  def self.unsubscribe!(user, source:)
    raise ArgumentError, "Unknown source #{source}" unless SOURCES.include?(source)

    now = Time.current
    # Assignments run left to right, so `subscribed` is still the old value until the last one.
    with_bounded_lock_wait do
      connection.exec_update(sanitize_sql_array([<<~SQL.squish, user.id, source, now, now, source, now]))
        INSERT INTO feature_announcement_subscriptions (user_id, subscribed, version, source, created_at, updated_at)
        VALUES (?, FALSE, 1, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
          version = IF(subscribed, version + 1, version),
          source = IF(subscribed, ?, source),
          updated_at = IF(subscribed, ?, updated_at),
          subscribed = FALSE
      SQL
    end
  end

  # Applies a Settings change only if nothing has written since the form was rendered.
  # Returns :unchanged, :updated or :stale.
  def self.update_from_settings!(user, subscribed:, rendered_version:)
    current = state_for(user)
    return :unchanged if current[:subscribed] == subscribed
    return :stale if current[:version] != rendered_version

    with_bounded_lock_wait do
      if rendered_version.zero?
        create!(user_id: user.id, subscribed:, source: "settings")
        :updated
      else
        affected = where(user_id: user.id, version: rendered_version)
          .update_all(["subscribed = ?, version = version + 1, source = 'settings', updated_at = ?", subscribed, Time.current])
        affected == 1 ? :updated : :stale
      end
    end
  rescue ActiveRecord::RecordNotUnique
    :stale
  end

  # Encrypted (SecureExternalId), so neither the user id nor the address is readable from the
  # link. The address digest ties the link to the recipient it was sent to.
  def self.unsubscribe_token(user, email)
    User.encrypt_id([user.id, address_digest(email)], scope: UNSUBSCRIBE_TOKEN_SCOPE)
  end

  # Returns [user_id, address_digest] or nil.
  def self.decode_unsubscribe_token(token)
    payload = User.decrypt_id(token, scope: UNSUBSCRIBE_TOKEN_SCOPE)
    return unless payload.is_a?(Array) && payload.size == 2
    return unless payload[0].is_a?(Integer) && payload[1].is_a?(String)

    payload
  end

  def self.address_digest(email)
    Digest::SHA256.hexdigest(email.to_s.strip.downcase)
  end

  def self.with_bounded_lock_wait
    previous = connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{LOCK_WAIT_SECONDS}")
    yield
  ensure
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous.to_i}") if previous.present?
  end
  private_class_method :with_bounded_lock_wait
end
