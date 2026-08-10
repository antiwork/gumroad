# frozen_string_literal: true

class InstallmentRule < ApplicationRecord
  VERSION_CACHE_TTL = 1.day
  PENDING_OWNER_CACHE_TTL = 5.minutes
  PENDING_VERSION_CACHE_TTL = PENDING_OWNER_CACHE_TTL + 1.minute
  CACHE_PENDING_VERSION_SCRIPT = <<~LUA
    local current = redis.call("GET", KEYS[1])
    if not current or tonumber(ARGV[1]) >= tonumber(current) then
      redis.call("SET", KEYS[1], ARGV[1], "EX", ARGV[3])
      redis.call("SET", KEYS[2], ARGV[2], "EX", ARGV[4])
      return tonumber(ARGV[1])
    end
    return tonumber(current)
  LUA
  CACHE_COMMITTED_VERSION_SCRIPT = <<~LUA
    local current = redis.call("GET", KEYS[1])
    local owner = redis.call("GET", KEYS[2])
    if current and tonumber(current) > tonumber(ARGV[1]) then
      return tonumber(current)
    end
    if owner and (ARGV[2] == "" or owner ~= ARGV[2]) then
      return current and tonumber(current) or false
    end
    redis.call("SET", KEYS[1], ARGV[1], "EX", ARGV[3])
    redis.call("DEL", KEYS[2])
    return tonumber(ARGV[1])
  LUA
  CLEAR_PENDING_VERSION_SCRIPT = <<~LUA
    if redis.call("GET", KEYS[2]) == ARGV[1] then
      return redis.call("DEL", KEYS[1], KEYS[2])
    end
    return 0
  LUA

  has_paper_trail version: :paper_trail_version

  include Deletable

  belongs_to :installment, optional: true

  # To show the proper time period to a user, we need to store this.
  # To a user, they should see "1 week" instead of "7 days."
  HOUR = "hour"
  DAY = "day"
  WEEK = "week"
  MONTH = "month"

  ABANDONED_CART_DELAYED_DELIVERY_TIME_IN_SECONDS = 24.hours.to_i

  validates_presence_of :installment, :version
  validate :to_be_published_at_cannot_be_in_the_past
  validate :to_be_published_at_must_exist_for_non_workflow_posts

  # A version change invalidates jobs that use old delivery or publication state.
  # The version starts at 1 although the schema default is 0. Jobs use version 0 when no rule exists.
  before_save :increment_version, if: :delivery_date_changed?
  # Publish before SQL so stale jobs cannot cross a transaction that changes delivery state.
  before_save :cache_pending_version, if: :publish_pending_version?
  after_commit :cache_committed_version, if: :workflow_rule?

  def self.cached_version(installment_id)
    $redis.get(RedisKey.workflow_installment_rule_version(installment_id))&.to_i
  end

  def self.cached_version_state(installment_id)
    version, owner = $redis.mget(*cache_keys(installment_id))
    [version&.to_i, owner.present?]
  end

  def self.cache_pending_version!(installment_id:, version:, token:)
    $redis.eval(
      CACHE_PENDING_VERSION_SCRIPT,
      keys: cache_keys(installment_id),
      argv: [version, token, PENDING_VERSION_CACHE_TTL.to_i, PENDING_OWNER_CACHE_TTL.to_i]
    ).to_i
  end

  def self.cache_committed_version!(installment_id:, version:, expected_pending_token: nil, expires_in: VERSION_CACHE_TTL)
    result = $redis.eval(
      CACHE_COMMITTED_VERSION_SCRIPT,
      keys: cache_keys(installment_id),
      argv: [version, expected_pending_token.to_s, expires_in.to_i]
    )
    result&.to_i
  end

  def self.clear_pending_version!(installment_id:, token:)
    $redis.eval(
      CLEAR_PENDING_VERSION_SCRIPT,
      keys: cache_keys(installment_id),
      argv: [token]
    )
  end

  def self.promote_pending_version(installment_id:, installment_rule_id:, version:, token:)
    cache_committed_version!(installment_id:, version:, expected_pending_token: token)
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, installment_rule_id:)
  end

  def self.clear_pending_version(installment_id:, installment_rule_id:, token:)
    clear_pending_version!(installment_id:, token:)
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, installment_rule_id:)
  end

  def cache_version!(expires_in: VERSION_CACHE_TTL)
    return if installment_id.nil?

    self.class.cache_committed_version!(installment_id:, version:, expires_in:)
  end

  def advance_version!
    with_lock { update!(version: version + 1) }
  end

  # Public: Converts the delayed_delivery_time back into the number the creator entered using the time period of the rule
  #
  # Examples
  #   delayed_delivery_time = 432000, time_period = "DAY"
  #   displayable_time_duration
  #   #=> 5
  #   delayed_delivery_time = 72000, time_period = "HOUR"
  #   displayable_time_duration
  #   # => 20
  #
  # Returns an integer
  def displayable_time_duration
    case time_period
    when HOUR
      period = 1.hour
    when DAY
      period = 1.day
    when WEEK
      period = 1.week
    when MONTH
      period = 1.month
    end
    (delayed_delivery_time / period).to_i
  end

  private
    def cache_pending_version
      token = SecureRandom.uuid
      rule_class = self.class
      pending_installment_id = installment_id
      pending_rule_id = id
      pending_version = version

      AfterCommitEverywhere.after_commit do
        rule_class.promote_pending_version(
          installment_id: pending_installment_id,
          installment_rule_id: pending_rule_id,
          version: pending_version,
          token:
        )
      end
      AfterCommitEverywhere.after_rollback do
        rule_class.clear_pending_version(
          installment_id: pending_installment_id,
          installment_rule_id: pending_rule_id,
          token:
        )
      end
      rule_class.cache_pending_version!(installment_id: pending_installment_id, version: pending_version, token:)
    end

    def publish_pending_version?
      workflow_rule? && will_save_change_to_version? && persisted?
    end

    def workflow_rule?
      installment&.workflow_id.present?
    end

    def cache_committed_version
      cache_version!
    rescue Redis::BaseError, RedisClient::Error => e
      ErrorNotifier.notify(e, installment_rule_id: id)
    end

    def self.cache_keys(installment_id)
      [
        RedisKey.workflow_installment_rule_version(installment_id),
        RedisKey.workflow_installment_rule_pending_token(installment_id),
      ]
    end
    private_class_method :cache_keys

    # Private: Increments version of InstallmentRule. This is so PublishInstallment jobs are ignored if the version of the job does not match the
    # most recent version of the InstallmentRule. We want to update the version every time the creator changes when it is scheduled.
    def increment_version
      self[:version] = version + 1
    end

    def delivery_date_changed?
      delayed_delivery_time_changed? || to_be_published_at_changed?
    end

    def to_be_published_at_must_exist_for_non_workflow_posts
      return if installment.blank?
      return if installment.workflow.present?
      return if to_be_published_at.present?

      errors.add(:base, "Please select a date and time in the future.")
    end

    def to_be_published_at_cannot_be_in_the_past
      return if deleted_at_changed?
      return if to_be_published_at.blank?
      return if to_be_published_at > Time.current

      errors.add(:base, "Please select a date and time in the future.")
    end
end
