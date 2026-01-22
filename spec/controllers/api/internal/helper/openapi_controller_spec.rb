# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_helper_api_method"

describe Api::Internal::Helper::OpenapiController do
  it "inherits from Api::Internal::Helper::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
  end

  describe "GET index" do
    include_examples "helper api authorization required", :get, :index

    it "returns openapi schema" do
      get :index
      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include(openapi: "3.1.0")
    end
  end
end
