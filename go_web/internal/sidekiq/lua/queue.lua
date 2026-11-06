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
local job_id     = ARGV[1]      -- The job_id that was previously primed
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
---------  END injected arguments ---------


--------  BEGIN Variables --------
local queued_count = redis.call("LLEN", queued)
local locked_count = redis.call("HLEN", locked)
local within_limit = limit > locked_count
local limit_exceeded = not within_limit
--------   END Variables  --------


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


--------  BEGIN queue.lua --------
log_debug("BEGIN queue with key:", digest, "for job:", job_id)

if redis.call("HEXISTS", locked, job_id) == 1 then
  log_debug("HEXISTS", locked, job_id, "== 1")
  log("Duplicate")
  return job_id
end

local prev_jid = redis.call("GET", digest)
log_debug("job_id:", job_id, "prev_jid:", prev_jid)
if not prev_jid or prev_jid == false then
  log_debug("SET", digest, job_id)
  redis.call("SET", digest, job_id)
elseif prev_jid == job_id then
  log_debug(digest, "already queued with job_id:", job_id)
  log("Duplicate")
  return job_id
else
  -- TODO: Consider constraining the total count of both locked and queued?
  if within_limit and queued_count < limit then
    log_debug("Within limit:", digest, "(",  locked_count, "of", limit, ")", "queued (", queued_count, "of", limit, ")")
    log_debug("SET", digest, job_id, "(was", prev_jid, ")")
    redis.call("SET", digest, job_id)
  else
    log_debug("Limit exceeded:", digest, "(",  locked_count, "of", limit, ")")
    log("Limit exceeded", prev_jid)
    return prev_jid
  end
end

log_debug("LPUSH", queued, job_id)
redis.call("LPUSH", queued, job_id)

-- The Sidekiq client should only set pttl for until_expired
-- The Sidekiq server should set pttl for all other jobs
if pttl and pttl > 0 then
  log_debug("PEXPIRE", digest, pttl)
  redis.call("PEXPIRE", digest, pttl)
  log_debug("PEXPIRE", queued, pttl)
  redis.call("PEXPIRE", queued, pttl)
end

log("Queued")
log_debug("END queue with key:", digest, "for job:", job_id)
return job_id
--------  END queue.lua --------
