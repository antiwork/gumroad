# frozen_string_literal: true

FactoryBot.define do
  factory "doorkeeper/access_token" do
    association :application, factory: :oauth_application
  end
end
