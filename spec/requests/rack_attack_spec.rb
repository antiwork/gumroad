# frozen_string_literal: true

require "spec_helper"

describe "Rack::Attack throttle", type: :request do
  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
  end

  describe "forgot_password throttle with malformed JSON params" do
    it "does not raise TypeError when json_params contain non-Hash nested values" do
      post "/forgot_password.json",
           params: { user: "not-a-hash" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      expect(response.status).not_to eq(500)
    end
  end
end
