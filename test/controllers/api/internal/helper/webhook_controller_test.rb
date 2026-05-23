# frozen_string_literal: true

require "test_helper"

class ApiInternalHelperWebhookControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::Helper::WebhookController
  tests Api::Internal::Helper::WebhookController

  # frozen_string_literal: false


  context_ Api::Internal::Helper::WebhookController do
    include HelperAISpecHelper

  test "inherits from Api::Internal::Helper::BaseController" do
      expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
    end

  context_ "POST handle" do
      let(:event) { "conversation.created" }
      let(:payload) { { "conversation_id" => "123" } }

      before do
        @params = { event:, payload:, timestamp: Time.current.to_i }
      end

  context_ "with valid parameters" do
  test "enqueues a HandleHelperEventWorker job" do
          expect do
            set_headers(json: @params)
            post :handle, params: @params
          end.to change(HandleHelperEventWorker.jobs, :size).by(1)

          expect(response).to be_successful
          expect(JSON.parse(response.body)).to eq({ "success" => true })
        end
      end

  context_ "with missing parameters" do
  test "returns a bad request status when event is missing" do
          params = @params.except(:event)
          set_headers(json: params)
          post :handle, params: params
          expect(response).to have_http_status(:bad_request)
          expect(JSON.parse(response.body)).to eq({ "success" => false, "error" => "missing required parameters" })
        end

  test "returns a bad request status when payload is missing" do
          params = @params.except(:payload)
          set_headers(json: params)
          post :handle, params: params
          expect(response).to have_http_status(:bad_request)
          expect(JSON.parse(response.body)).to eq({ "success" => false, "error" => "missing required parameters" })
        end
      end
    end
  end
end
