# frozen_string_literal: true

require "spec_helper"

describe "filter parameter logging configuration" do
  it "filters OAuth device flow bearer secrets" do
    expect(Rails.application.config.filter_parameters).to include(:client_secret, :device_code, :user_code)
  end
end
