# frozen_string_literal: true

require "spec_helper"

describe "removed Gumroad Walks API" do
  { API_DOMAIN => "/v2", DOMAIN => "/api/v2" }.each do |host, prefix|
    %w[realtime_tokens synthesis app_attest/challenges app_attest/attestations].each do |operation|
      url = "https://#{host}#{prefix}/walks/#{operation}"

      it "does not route POST #{url}" do
        expect do
          Rails.application.routes.recognize_path(url, method: :post)
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
