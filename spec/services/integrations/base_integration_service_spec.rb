# frozen_string_literal: true

require "spec_helper"

describe Integrations::BaseIntegrationService do
  it "raises runtime error on direct instantiation" do
    expect { Integrations::BaseIntegrationService.new }.to raise_error(RuntimeError, "Integrations::BaseIntegrationService should not be instantiated. Instantiate child classes instead.")
  end
end
