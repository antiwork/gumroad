# frozen_string_literal: true

require "spec_helper"

describe "removed Gumroad Walks API" do
  %w[
    /v2/walks/realtime_tokens
    /api/v2/walks/realtime_tokens
    /v2/walks/synthesis
    /api/v2/walks/synthesis
    /v2/walks/app_attest/challenges
    /api/v2/walks/app_attest/attestations
  ].each do |path|
    it "does not route POST #{path}" do
      expect {
        Rails.application.routes.recognize_path(path, method: :post)
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
