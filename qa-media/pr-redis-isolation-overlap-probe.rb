#!/usr/bin/env ruby
# frozen_string_literal: true

# Overlap probe for the pre-merge review finding on this branch. Evidence artifact, not
# part of the suite — captured output in qa-media/pr-redis-isolation-overlap-probe.txt.
#
# The race this branch fixes has a second form the first probe does not reach. A run that
# SKIPS leasing keeps the .env.test databases and flushes them. If a leased block contains
# any of those indexes, that run wipes the leaseholder's keys while the leaseholder holds a
# valid lease and believes it is isolated — the original race, now harder to see.
#
# The original arithmetic dealt blocks from database 4 upward, so slot 1 was [8,9,10,11]
# and slot 2 was [12,13,14,15]: both straddle the .env.test block [10,11,12,13].
#
# Each role boots the real app so the leasing code runs exactly as it does in a test run.
# The writer stores one key per store it was given; the flusher runs the `flushdb` both
# suites run before every test, once per store IT was given. The writer then reports which
# of its own databases were erased by a process that never touched its lease.
#
#   RUN_ID=x ROLE=writer  bundle exec ruby qa-media/pr-redis-isolation-overlap-probe.rb &
#   RUN_ID=x ROLE=flusher DISABLE_TEST_REDIS_ISOLATION=1 bundle exec ruby ...
require_relative "../config/environment"

role = ENV.fetch("ROLE")
run = ENV.fetch("RUN_ID")
key = "overlap-probe-key"
stores = TestRedisIsolation::STORE_ENV_VARS
server = ENV.fetch("REDIS_HOST").split("/").first
databases = stores.map { |var| ENV.fetch(var).split("/").last.to_i }

def connect(server, database)
  Redis.new(url: "redis://#{server}/#{database}")
end

# Barrier on a database no slot and no fallback is assigned, so neither side clears it.
barrier = connect(server, ENV.fetch("BARRIER_DB", "62"))
barrier.sadd("overlap-barrier:#{run}", role)
barrier.expire("overlap-barrier:#{run}", 180)

if role == "writer"
  databases.each { |database| connect(server, database).set(key, "written-by-writer") }
end

deadline = Time.now + 90
until barrier.scard("overlap-barrier:#{run}") >= 2
  abort("#{role}: barrier timed out waiting for the other process") if Time.now > deadline
  sleep 0.05
end

case role
when "writer"
  puts "writer   leased databases #{databases.inspect}"
  60.times { sleep 0.1 }
  wiped = databases.reject { |database| connect(server, database).get(key) }
  if wiped.empty?
    puts "writer   SURVIVED — no leased database was flushed by the fallback run"
  else
    puts "writer   WIPED databases #{wiped.inspect} — flushed by a run holding no lease on them"
  end
when "flusher"
  puts "flusher  fallback databases #{databases.inspect} (no lease held)"
  connections = databases.map { |database| connect(server, database) }
  60.times do
    connections.each(&:flushdb)
    sleep 0.05
  end
  puts "flusher  done"
end
