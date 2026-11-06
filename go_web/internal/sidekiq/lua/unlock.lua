-------- BEGIN keys ---------
local digest    = KEYS[1]
local queued    = KEYS[2]
local primed    = KEYS[3]
local locked    = KEYS[4]
local info      = KEYS[5]
local changelog = KEYS[6]
local digests   = KEYS[7]
-------- END keys ---------


-------- BEGIN lock arguments ---------
local job_id     = ARGV[1]
local pttl       = tonumber(ARGV[2])
local lock_type  = ARGV[3]
local limit      = tonumber(ARGV[4])
local lock_score = ARGV[5]
-------- END lock arguments -----------


--------  BEGIN injected arguments --------
local current_time = tonumber(ARGV[6])
local debug_lua    = tostring(ARGV[7]) == "1"
local max_history  = tonumber(ARGV[8])
local script_name  = tostring(ARGV[9]) .. ".lua"
local redisversion = ARGV[10]
---------  END injected arguments ---------


--------  BEGIN Variables --------
local queued_count = redis.call("LLEN", queued)
local primed_count = redis.call("LLEN", primed)
local locked_count = redis.call("HLEN", locked)
---------  END Variables ---------


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


---------  Begin unlock.lua ---------
log_debug("BEGIN unlock digest:", digest, "(job_id: " .. job_id ..")")

log_debug("HEXISTS", locked, job_id)
if redis.call("HEXISTS", locked, job_id) == 0 then
  -- TODO: Improve orphaned lock detection
  if queued_count == 0 and primed_count == 0 and locked_count == 0 then
    log_debug("Orphaned lock")
  else
    local result = ""
    for i,v in ipairs(redis.call("HKEYS", locked)) do
      result = result .. v .. ","
    end
    result = locked .. " (" .. result .. ")"
    log("Yielding to: " .. result)
    log_debug("Yielding to", result, locked, "by job", job_id)
    return nil
  end
end

-- Just in case something went wrong
log_debug("LREM", queued, -1, job_id)
redis.call("LREM", queued, -1, job_id)

log_debug("LREM", primed, -1, job_id)
redis.call("LREM", primed, -1, job_id)

local redis_version = toversion(redisversion)

if lock_type ~= "until_expired" then
  log_debug("UNLINK", digest, info)
  redis.call("UNLINK", digest, info)

  log_debug("HDEL", locked, job_id)
  redis.call("HDEL", locked, job_id)
end

if redis.call("LLEN", primed) == 0 then
  log_debug("UNLINK", primed)
  redis.call("UNLINK", primed)
end

local locked_count = redis.call("HLEN", locked)

if locked_count < 1 then
  log_debug("UNLINK", locked)
  redis.call("UNLINK", locked)
end

if limit then
  if limit <= 1 and locked_count <= 1 then
    log_debug("ZREM", digests, digest)
    redis.call("ZREM", digests, digest)
  end
else
  if locked_count <= 1 then
    log_debug("ZREM", digests, digest)
    redis.call("ZREM", digests, digest)
  end
end

log_debug("LPUSH", queued, "1")
redis.call("LPUSH", queued, "1")

log_debug("PEXPIRE", queued, 5000)
redis.call("PEXPIRE", queued, 5000)

log("Unlocked")
log_debug("END unlock digest:", digest, "(job_id: " .. job_id ..")")
return job_id
---------  END unlock.lua ---------
