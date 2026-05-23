# frozen_string_literal: true

require "test_helper"

class ConfigInitializersSentryTest < ActiveSupport::TestCase



  context_ "Sentry configuration" do
  test "is not enabled in the test environment" do
      expect(Sentry.configuration.enabled_in_current_env?).to eq(false)
    end

  test "only enables production and staging environments" do
      expect(Sentry.configuration.enabled_environments).to eq(%w[production staging])
    end
  end
end
