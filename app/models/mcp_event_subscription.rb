# frozen_string_literal: true

# A lease on webhook delivery of one seller event to an MCP client. The client keeps it alive by
# subscribing again with the same key before expires_at; a row past that delivers nothing. Rows
# are deleted, never soft-deleted: each holds the client's signing secret.
class McpEventSubscription < ApplicationRecord
  SALE_CREATED = "sale.created"
  EVENT_NAMES = [SALE_CREATED].freeze
  # A Standard Webhooks symmetric secret: the prefix, then the base64 of this many random bytes.
  SECRET_PREFIX = "whsec_"
  SECRET_BYTE_RANGE = (24..64)
  SECRET_ERROR = "must be #{SECRET_PREFIX} followed by the base64 of #{SECRET_BYTE_RANGE.min} to #{SECRET_BYTE_RANGE.max} random bytes"
  MAX_CALLBACK_URL_LENGTH = 2048
  MAX_ARGUMENTS_BYTES = 1.kilobyte
  # A shorter lease would have a client refreshing in a loop.
  MIN_TTL = 5.minutes
  # Also the default. It bounds how long an abandoned subscription stays live.
  MAX_TTL = 1.day
  # A connection is one seller's grant to one OAuth application.
  MAX_LIVE_PER_CONNECTION = 20
  # A token needs one of these to subscribe, and the connection needs one for a delivery to go out.
  SCOPES = %i[view_sales account].freeze
  PUBLIC_ID_PREFIX = "sub_"
  PUBLIC_ID_DIGEST_LENGTH = 32

  self.filter_attributes += [:secret]

  belongs_to :user
  belongs_to :oauth_application

  attribute :arguments, :json, default: -> { {} }
  # The key. A different value in any of these addresses a different subscription.
  attr_readonly :user_id, :oauth_application_id, :event_name, :arguments, :callback_url, :key_digest

  before_validation :set_key_digest, on: :create

  validates :event_name, inclusion: { in: EVENT_NAMES }
  validates :callback_url, length: { maximum: MAX_CALLBACK_URL_LENGTH }
  validate :callback_url_is_https
  validate :secret_is_a_standard_webhooks_secret
  validate :arguments_are_a_small_object
  validate :connection_has_a_free_slot

  scope :live, -> { where("mcp_event_subscriptions.expires_at > ?", Time.current) }
  scope :expired, -> { where("mcp_event_subscriptions.expires_at <= ?", Time.current) }

  class << self
    # Creates the subscription for this key, or refreshes the one that exists: a new lease, and the
    # secret replaced, which is how a client rotates it. `ttl` is the lifetime the client suggests,
    # in seconds.
    def subscribe!(user:, oauth_application:, event_name:, arguments:, callback_url:, secret:, ttl: nil)
      key_digest = key_digest_for(user_id: user.id, oauth_application_id: oauth_application.id, event_name:, arguments:, callback_url:)
      lease = { secret:, expires_at: Time.current + granted_ttl(ttl) }
      transaction do
        # The transaction's first read, so the limit's count after it sees what a subscribe that
        # held the lock before this one committed.
        lock_seller!(user.id)
        subscription = find_by(key_digest:) ||
          create_or_find_by!(key_digest:) { _1.assign_attributes(user:, oauth_application:, event_name:, arguments:, callback_url:, **lease) }
        # A refresh, or a first subscribe that lost a race and got the winner's row.
        subscription.update!(lease) unless subscription.previously_new_record?
        subscription
      end
    end

    # One seller's subscribes run one after another, so two at once cannot both pass the limit.
    # Take it before any token row: account closure locks the seller, then the seller's tokens.
    def lock_seller!(user_id)
      User.where(id: user_id).lock.pick(:id)
    end

    def valid_secret?(value)
      value.is_a?(String) && value.start_with?(SECRET_PREFIX) &&
        SECRET_BYTE_RANGE.cover?(Base64.strict_decode64(value.delete_prefix(SECRET_PREFIX)).bytesize)
    rescue ArgumentError
      false
    end

    # The same values address the same row, whatever order the client wrote the arguments in.
    def key_digest_for(user_id:, oauth_application_id:, event_name:, arguments:, callback_url:)
      Digest::SHA256.hexdigest([user_id, oauth_application_id, callback_url, event_name, canonical(arguments)].to_json)
    end

    private
      # The client suggests and the server decides: a suggestion outside the bounds is held inside
      # them, never refused.
      def granted_ttl(suggested)
        return MAX_TTL if suggested.nil?

        suggested.to_i.clamp(MIN_TTL.to_i, MAX_TTL.to_i).seconds
      end

      def canonical(value)
        case value
        when Hash then value.sort_by(&:first).to_h.transform_values { canonical(_1) }
        when Array then value.map { |member| canonical(member) }
        else value
        end
      end
  end

  # The client's name for the subscription. Derived from the key, not random, because a refresh
  # must answer with the id the first subscribe gave. It is never accepted as input.
  def public_id
    "#{PUBLIC_ID_PREFIX}#{key_digest.first(PUBLIC_ID_DIGEST_LENGTH)}"
  end

  # Revoking one token, or authorizing again with fewer scopes, deletes no row, so a delivery asks
  # the token table each time.
  def access_granted?
    Doorkeeper::AccessToken.active_for(user_id).where(application_id: oauth_application_id).any? do |token|
      # The endpoint's own rule too: a team member's token ends with the membership.
      SCOPES.any? { token.includes_scope?(_1) } && MobileAccountToken.valid?(token)
    end
  end

  private
    def set_key_digest
      self.key_digest = self.class.key_digest_for(user_id:, oauth_application_id:, event_name:, arguments:, callback_url:)
    end

    def callback_url_is_https
      errors.add(:callback_url, "must be an https URL without credentials") unless https_url_without_credentials?
    end

    # The signature is the only authentication a delivery carries, so a URL has no use for a password.
    def https_url_without_credentials?
      uri = URI.parse(callback_url.to_s)
      uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
    rescue URI::InvalidURIError
      false
    end

    def secret_is_a_standard_webhooks_secret
      errors.add(:secret, SECRET_ERROR) unless self.class.valid_secret?(secret)
    end

    def arguments_are_a_small_object
      if !arguments.is_a?(Hash)
        errors.add(:arguments, "must be an object")
      elsif arguments.to_json.bytesize > MAX_ARGUMENTS_BYTES
        errors.add(:arguments, "must be at most #{MAX_ARGUMENTS_BYTES} bytes of JSON")
      end
    end

    # Counts leases, not rows: an expired subscription holds no slot until a refresh revives it.
    def connection_has_a_free_slot
      others = self.class.live.where(user_id:, oauth_application_id:)
      others = others.where.not(id:) if persisted?
      return if others.count < MAX_LIVE_PER_CONNECTION

      errors.add(:base, "This connection already has #{MAX_LIVE_PER_CONNECTION} live event subscriptions. Unsubscribe from one first.")
    end
end
