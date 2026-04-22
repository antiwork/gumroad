# frozen_string_literal: true


Mongoid.load!(Rails.root.join("config", "mongoid.yml"))
MONGO_DATABASE = Mongoid::Clients.default
