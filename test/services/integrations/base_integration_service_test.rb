# frozen_string_literal: true

require "test_helper"

class Integrations::BaseIntegrationServiceTest < ActiveSupport::TestCase
  test "raises a runtime error on direct instantiation" do
    error = assert_raises(RuntimeError) { Integrations::BaseIntegrationService.new }
    assert_equal "Integrations::BaseIntegrationService should not be instantiated. Instantiate child classes instead.", error.message
  end
end
