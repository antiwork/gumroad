# frozen_string_literal: true

require "spec_helper"

describe "POST /orders with a malformed cart", type: :request do
  before { host! DOMAIN }

  it "answers 400 for a line_items payload that is not an array" do
    post "/orders", params: { line_items: "not-an-array" }, as: :json

    expect(response).to have_http_status(:bad_request)
  end

  it "answers 400 for a scalar line_items entry" do
    post "/orders", params: { line_items: ["unique-id-0"] }, as: :json

    expect(response).to have_http_status(:bad_request)
  end

  it "answers 400 for a scalar line_items entry on prepare" do
    post "/orders/prepare", params: { line_items: ["unique-id-0"] }, as: :json

    expect(response).to have_http_status(:bad_request)
  end
end
