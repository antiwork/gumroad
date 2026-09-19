#!/usr/bin/env ruby
# Stage one base64 chunk into Redis (custom landing page publish - mfhpmi)
require "base64"
chunk = "<B64CHUNK>"
idx = <IDX>
key = "mfhpmi_115fe_#{idx}"
raise "chunk sha mismatch" unless Digest::SHA256.hexdigest(chunk)[0,16] == "<CHUNKSHA>"
$redis.set(key, chunk, ex: 7200)
raise "redis set failed" unless $redis.get(key) == chunk
puts "staged #{key} len=#{chunk.length} ttl=#{$redis.ttl(key)}"