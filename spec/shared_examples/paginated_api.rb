# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "a paginated API" do
  it "contains pagination meta in the response body" do
    get @action, params: @params
    expect(response.status).to eq(200)
    expect(response.parsed_body[@response_key_name].size).to eq(@records.size)
    expect(response.parsed_body["meta"]["pagination"].keys).to match_array(%w[count items last next page pages prev])
  end

  it "can paginate and customize the number of items per page" do
    get @action, params: @params
    expect(response.status).to eq(200)
    expect(response.parsed_body[@response_key_name].size).to eq(@records.size)

    get @action, params: @params.merge(items: 1)
    expect(response.status).to eq(200)
    expect(response.parsed_body[@response_key_name].size).to eq(1)
    first_page_result = response.parsed_body[@response_key_name].first

    get @action, params: @params.merge(items: 1, page: 2)
    expect(response.status).to eq(200)
    expect(response.parsed_body[@response_key_name].size).to eq(1)
    second_page_result = response.parsed_body[@response_key_name].first
    expect(first_page_result).not_to eq(second_page_result)
  end

  it "returns 400 error if page param is incorrect" do
    get @action, params: @params.merge(page: 1_000)
    expect(response.status).to eq(400)
    expect(response.parsed_body["error"]["message"]).to include("expected :page in 1..1")
  end
end
