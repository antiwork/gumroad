# frozen_string_literal: true

class TeamInvitationThrottle
  LIMITS = { "hour" => [10, 1.hour], "day" => [50, 24.hours] }.freeze

  # A seller we have not reviewed gets this many invitations in total, revoked ones included. The
  # mailer carries the inviter's identity to strangers from our own sending domain, so an account
  # that has not been reviewed waits for review rather than for the next window.
  UNREVIEWED_TOTAL_LIMIT = 3

  # Check both windows and reserve a send atomically. Redis supplies the clock for every app process.
  CHECK_SCRIPT = <<~LUA
    local time = redis.call("TIME")
    local now = tonumber(time[1]) + tonumber(time[2]) / 1000000
    redis.call("ZREMRANGEBYSCORE", KEYS[1], "-inf", now - tonumber(ARGV[2]))
    local restriction = {"", 0, 0}

    for i = 3, #ARGV, 3 do
      local name, limit, period = ARGV[i], tonumber(ARGV[i + 1]), tonumber(ARGV[i + 2])
      local cutoff = "(" .. (now - period)
      local count = redis.call("ZCOUNT", KEYS[1], cutoff, "+inf")
      if count >= limit then
        local oldest = redis.call("ZRANGEBYSCORE", KEYS[1], cutoff, "+inf", "WITHSCORES", "LIMIT", count - limit, 1)
        local wait = math.ceil(tonumber(oldest[2]) + period - now)
        if wait > restriction[3] then restriction = {name, limit, wait} end
      end
    end

    if restriction[3] > 0 then return restriction end
    redis.call("ZADD", KEYS[1], now, ARGV[1])
    redis.call("EXPIRE", KEYS[1], ARGV[2])
    return {}
  LUA

  def self.check(seller_id)
    window, limit, retry_after = $redis.eval(
      CHECK_SCRIPT,
      keys: [RedisKey.team_invitation_send_throttle(seller_id)],
      argv: [SecureRandom.uuid, LIMITS.values.map(&:last).max.to_i, *LIMITS.flat_map { |name, (count, period)| [name, count, period.to_i] }]
    )
    { window:, limit:, retry_after: } if window
  end

  # Only a reviewed, active seller is trusted with the per-window allowance. Suspending an account
  # does not reset `user_risk_state`, so a seller marked compliant before being shut down still
  # reads `compliant?`; the activity check is what closes that gap.
  def self.trusted_sender?(seller)
    seller.compliant? && seller.account_active?
  end

  # Revoked invitations still count: revoking and re-inviting is how an abuser would otherwise
  # recycle the allowance.
  def self.unreviewed_limit_reached?(seller)
    return false if trusted_sender?(seller)

    seller.team_invitations.count >= UNREVIEWED_TOTAL_LIMIT
  end
end
