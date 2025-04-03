# frozen_string_literal: false

require "spec_helper"

describe Api::Internal::Helper::WebhookController do
  include HelperAISpecHelper

  it "inherits from Api::Internal::Helper::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
  end

  describe "POST handle" do
    let(:event) { "conversation.created" }
    let(:payload) { { "conversation_id" => "123" } }

    before do
      @params = { event:, payload:, timestamp: Time.current.to_i }
    end

    context "with valid parameters" do
      it "enqueues a HandleHelperEventWorker job" do
        expect do
          set_headers(json: @params)
          post :handle, params: @params
        end.to change(HandleHelperEventWorker.jobs, :size).by(1)

        expect(response).to be_successful
        expect(JSON.parse(response.body)).to eq({ "success" => true })
      end
    end

    context "with missing parameters" do
      it "returns a bad request status when event is missing" do
        params = @params.except(:event)
        set_headers(json: params)
        post :handle, params: params
        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)).to eq({ "success" => false, "error" => "missing required parameters" })
      end

      it "returns a bad request status when payload is missing" do
        params = @params.except(:payload)
        set_headers(json: params)
        post :handle, params: params
        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)).to eq({ "success" => false, "error" => "missing required parameters" })
      end
    end
  end
end
