# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Helper::OpenapiController do
  it "inherits from Api::Internal::Helper::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
  end

  describe "GET index" do
    it "returns openapi schema" do
      request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
      get :index
      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include(openapi: "3.1.0")
    end
  end
end
