-------- BEGIN keys ---------
local digest           = KEYS[1]
local queued           = KEYS[2]
local primed           = KEYS[3]
local locked           = KEYS[4]
local info             = KEYS[5]
local changelog        = KEYS[6]
local digests          = KEYS[7]
local expiring_digests = KEYS[8]
-------- END keys ---------


-------- BEGIN lock arguments ---------
local job_id       = ARGV[1]
local pttl         = tonumber(ARGV[2])
local lock_type    = ARGV[3]
local limit        = tonumber(ARGV[4])
local lock_score   = ARGV[5]
-------- END lock arguments -----------


--------  BEGIN injected arguments --------
local current_time = tonumber(ARGV[6])
local debug_lua    = tostring(ARGV[7]) == "1"
local max_history  = tonumber(ARGV[8])
local script_name  = tostring(ARGV[9]) .. ".lua"
local redisversion = ARGV[10]
---------  END injected arguments ---------


--------  BEGIN local functions --------
local function toversion(version)
  local _, _, maj, min, pat = string.find(version, "(%d+)%.(%d+)%.(%d+)")

  return {
    ["version"] = version,
    ["major"]   = tonumber(maj),
    ["minor"]   = tonumber(min),
    ["patch"]   = tonumber(pat)
  }
end

local function log_debug( ... )
  if debug_lua ~= true then return end

  local result = ""
  for _,v in ipairs(arg) do
    result = result .. " " .. tostring(v)
  end
  redis.log(redis.LOG_DEBUG, script_name .. " -" ..  result)
end

local function log(message, prev_jid)
  if not max_history or max_history == 0 then return end
  local entry = cjson.encode({digest = digest, job_id = job_id, script = script_name, message = message, time = current_time, prev_jid = prev_jid })

  log_debug("ZADD", changelog, current_time, entry);
  redis.call("ZADD", changelog, current_time, entry);
  local total_entries = redis.call("ZCARD", changelog)
  local removed_entries = redis.call("ZREMRANGEBYRANK", changelog, 0, -1 * max_history)
  if removed_entries > 0 then
    log_debug("Removing", removed_entries , "entries from changelog (total entries", total_entries, "exceeds max_history:", max_history ..")");
  end
  log_debug("PUBLISH", changelog, entry);
  redis.call("PUBLISH", changelog, entry);
end

----------  END local functions ----------


---------  BEGIN lock.lua ---------
log_debug("BEGIN lock digest:", digest, "job_id:", job_id)

if redis.call("HEXISTS", locked, job_id) == 1 then
  log_debug(locked, "already locked with job_id:", job_id)
  log("Duplicate")

  log_debug("LREM", queued, -1, job_id)
  redis.call("LREM", queued, -1, job_id)

  log_debug("LREM", primed, 1, job_id)
  redis.call("LREM", primed, 1, job_id)

  return job_id
end

local locked_count   = redis.call("HLEN", locked)
local within_limit   = limit > locked_count
local limit_exceeded = not within_limit

if limit_exceeded then
  log_debug("Limit exceeded:", digest, "(",  locked_count, "of", limit, ")")
  log("Limited")
  return nil
end

if lock_type == "until_expired" and pttl and pttl > 0 then
  log_debug("ZADD", expiring_digests, current_time + pttl, digest)
  redis.call("ZADD", expiring_digests, current_time + pttl, digest)
else
  local score

  if #lock_score == 0 then
    score = current_time
  else
    score = lock_score
  end

  log_debug("ZADD", digests, score, digest)
  redis.call("ZADD", digests, score, digest)
end

log_debug("HSET", locked, job_id, current_time)
redis.call("HSET", locked, job_id, current_time)

log_debug("LREM", queued, -1, job_id)
redis.call("LREM", queued, -1, job_id)

log_debug("LREM", primed, 1, job_id)
redis.call("LREM", primed, 1, job_id)

-- The Sidekiq client sets pttl
if pttl and pttl > 0 then
  log_debug("PEXPIRE", digest, pttl)
  redis.call("PEXPIRE", digest, pttl)

  log_debug("PEXPIRE", locked, pttl)
  redis.call("PEXPIRE", locked, pttl)

  log_debug("PEXPIRE", info, pttl)
  redis.call("PEXPIRE", info, pttl)
end

log_debug("PEXPIRE", queued, 1000)
redis.call("PEXPIRE", queued, 1000)

log_debug("PEXPIRE", primed, 1000)
redis.call("PEXPIRE", primed, 1000)

log("Locked")
log_debug("END lock digest:", digest, "job_id:", job_id)
return job_id
----------  END lock.lua  ----------
