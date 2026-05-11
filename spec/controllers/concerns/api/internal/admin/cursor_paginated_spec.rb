# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::CursorPaginated do
  controller(ActionController::Base) do
    include Api::Internal::Admin::CursorPaginated

    def index
      render json: { limit: cursor_limit }
    end

    def invalid
      raise Api::Internal::Admin::CursorPagination::InvalidCursor
    end

    def mismatched
      paginate_with_cursor(Payment.all, order: [[:created_at, :desc], [:id, :desc]])
      render json: { success: true }
    end
  end

  before do
    routes.draw do
      get :index, to: "anonymous#index"
      get :invalid, to: "anonymous#invalid"
      get :mismatched, to: "anonymous#mismatched"
    end
  end

  it "returns a bad request response for invalid cursors" do
    get :invalid

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
  end

  it "returns a bad request response when a signed cursor has the wrong sort keys" do
    cursor = Api::Internal::Admin::CursorPagination.encode("id" => 1)

    get :mismatched, params: { cursor: }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
  end

  it "uses the default limit when the limit parameter is missing" do
    get :index

    expect(response.parsed_body["limit"]).to eq(described_class::DEFAULT_LIMIT)
  end

  it "uses the requested limit when it is in range" do
    get :index, params: { limit: 37 }

    expect(response.parsed_body["limit"]).to eq(37)
  end

  it "caps the requested limit at the maximum" do
    get :index, params: { limit: 10_000 }

    expect(response.parsed_body["limit"]).to eq(described_class::MAX_LIMIT)
  end

  it "uses the default limit when the requested limit is non-positive or non-numeric" do
    ["0", "-5", "abc", "2abc", ""].each do |limit|
      get :index, params: { limit: }

      expect(response.parsed_body["limit"]).to eq(described_class::DEFAULT_LIMIT), "limit=#{limit.inspect}"
    end
  end
end
