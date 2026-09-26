require "active_support/all"
require_relative "app/services/adult_keyword_detector"
name = "Sara Bee piledrivers and pin only"
desc = '<p>This clip features only the two piledrivers that "Goddess" Sara Bee takes from the Italian Stallion followed by the inevitable pin, in which he informs her that her session world is now "complete" as she\'s had the distinct honor and privilege of being piledriven by the one and only Italian Stallion.</p>'
puts "name adult? #{AdultKeywordDetector.adult?(name)}"
puts "desc adult? #{AdultKeywordDetector.adult?(desc)}"
desc.split(/[^A-Za-z]+/).uniq.each { |w| puts "trigger: #{w}" if AdultKeywordDetector.adult?(w) }
["Goddess", "pin", "piledrivers", "spanking", "Pinonly", "pin only"].each { |t| puts "#{t} -> #{AdultKeywordDetector.adult?(t)}" }