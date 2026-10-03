require "base64"
n = 0
(0..8).each { |i| n += 1 if $redis.del("mz1a0b76_#{i}") }
puts "redis_chunks_deleted=#{n}"
