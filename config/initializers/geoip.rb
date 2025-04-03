# frozen_string_literal: true

require "maxmind/geoip2"

database_path = "#{Rails.root}/lib/GeoIP2-City.mmdb"
GEOIP = File.exist?(database_path) ? MaxMind::GeoIP2::Reader.new(database: database_path) : nil
