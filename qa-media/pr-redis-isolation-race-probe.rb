#!/usr/bin/env ruby
# frozen_string_literal: true

# Two-process race harness for gumroad-private#1641. Evidence artifact, not part of the
# suite — see qa-media/pr-redis-isolation-race-probe.txt for its captured output.
#
# Boots the real Rails app twice against ONE Redis server, exactly as two concurrent
# test runs do. The writer stores the key the failing LinkTest depends on; the flusher
# loops on the same `$redis.flushdb` both suites run before every test
# (test/test_helper.rb, spec/spec_helper.rb). The writer then reads its own key back
# and prints SURVIVED or WIPED.
#
# The two processes rendezvous on a barrier before doing any of that, because Rails
# boot takes ~15s and without a barrier the faster process finishes before the other
# has connected — which looks like a pass and proves nothing. The barrier lives on a
# raw connection to a database no run is assigned, so flushdb cannot clear it.
#
#   RUN_ID=x ROLE=writer  bundle exec ruby qa-media/pr-redis-isolation-race-probe.rb &
#   RUN_ID=x ROLE=flusher bundle exec ruby qa-media/pr-redis-isolation-race-probe.rb
#
# Add DISABLE_TEST_REDIS_ISOLATION=1 to both to see the pre-fix behavior.
require_relative "../config/environment"

role = ENV.fetch("ROLE")
key = "race-probe-force-product-id-timestamp"
database = $redis.connection.fetch(:db)
server = ENV.fetch("REDIS_HOST").split("/").first
barrier = Redis.new(url: "redis://#{server}/#{ENV.fetch('BARRIER_DB', '15')}")
run = ENV.fetch("RUN_ID")

barrier.sadd("race-barrier:#{run}", role)
barrier.expire("race-barrier:#{run}", 120)
deadline = Time.now + 60
until barrier.scard("race-barrier:#{run}") >= 2
  abort("#{role}: barrier timed out waiting for the other process") if Time.now > deadline
  sleep 0.05
end

case role
when "writer"
  $redis.set(key, Time.now.to_s)
  50.times { sleep 0.1 }
  value = $redis.get(key)
  puts "writer db=#{database} #{value.nil? ? 'WIPED' : 'SURVIVED'}"
when "flusher"
  60.times do
    $redis.flushdb
    sleep 0.05
  end
  puts "flusher db=#{database} done"
end
