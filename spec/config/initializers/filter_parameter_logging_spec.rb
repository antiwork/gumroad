# frozen_string_literal: true

require "spec_helper"

describe "filter parameter logging configuration" do
  it "filters OAuth device flow bearer secrets" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    parameters = {
      client_secret: "secret",
      device_code: "device-code",
      user_code: "user-code",
      visible: "safe",
      nested: { "client_secret" => "nested-secret" },
    }
    filtered_parameters = {
      client_secret: "[FILTERED]",
      device_code: "[FILTERED]",
      user_code: "[FILTERED]",
      visible: "safe",
      nested: { "client_secret" => "[FILTERED]" },
    }

    expect(filter.filter(parameters)).to eq(filtered_parameters)
  end
end
