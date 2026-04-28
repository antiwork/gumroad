# frozen_string_literal: true

require "spec_helper"

describe "Sentry configuration" do
  it "is not enabled in the test environment" do
    expect(Sentry.configuration.enabled_in_current_env?).to eq(false)
  end

  it "only enables production and staging environments" do
    expect(Sentry.configuration.enabled_environments).to eq(%w[production staging])
  end
end
