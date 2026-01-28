# frozen_string_literal: true

require File.join(Rails.root, "lib", "extras", "mongoer")

Mongoid.load!(Rails.root.join("config", "mongoid.yml"))
MONGO_DATABASE = Mongoid::Clients.default
