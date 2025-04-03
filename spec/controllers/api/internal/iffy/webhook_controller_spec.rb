# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Iffy::WebhookController do
  include IffySpecHelper

  it "inherits from Api::Internal::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::BaseController)
  end

  describe "POST handle" do
    let(:timestamp) { (Time.current.to_f * 1000).to_i }

    context "with record.flagged event" do
      let(:event) { "record.flagged" }
      let(:payload) { { clientId: "123", entity: "Product" } }

      before do
        @json = { event:, payload:, timestamp: }
      end

      it "enqueues an Iffy::EventJob and returns ok" do
        expect do
          set_headers(json: @json)
          post :handle, body: @json.to_json, format: :json
        end.to change(Iffy::EventJob.jobs, :size).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to be_empty
      end
    end

    context "with user.suspended event" do
      let(:event) { "user.suspended" }
      let(:payload) { { clientId: "456" } }

      before do
        @json = { event:, payload:, timestamp: }
      end

      it "enqueues an Iffy::EventJob and returns ok" do
        expect do
          set_headers(json: @json)
          post :handle, body: @json.to_json, format: :json
        end.to change(Iffy::EventJob.jobs, :size).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to be_empty
      end
    end

    context "with record.flagged event and optional user" do
      let(:event) { "record.flagged" }
      let(:payload) { { clientId: "123", entity: "Product", user: { protected: true } } }

      before do
        @json = { event:, payload:, timestamp: }
      end

      it "enqueues an Iffy::EventJob with user data and returns ok" do
        expect do
          set_headers(json: @json)
          post :handle, body: @json.to_json, format: :json
        end.to change(Iffy::EventJob.jobs, :size).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to be_empty

        job = Iffy::EventJob.jobs.last
        expect(job["args"]).to eq([event, payload[:clientId], payload[:entity], { "protected" => true }.as_json])
      end
    end

    context "with missing parameters" do
      let(:event) { "record.flagged" }
      let(:payload) { { clientId: "123", entity: "Product" } }

      before do
        @json = { event:, payload:, timestamp: }
      end

      it "returns a bad request status when event is missing" do
        json = @json.except(:event)
        set_headers(json:)
        expect do
          post :handle, body: json.to_json, format: :json
        end.to raise_error(ActionController::ParameterMissing, "param is missing or the value is empty: event")
      end

      it "returns a bad request status when payload is missing" do
        json = @json.except(:payload)
        set_headers(json:)
        expect do
          post :handle, body: json.to_json, format: :json
        end.to raise_error(ActionController::ParameterMissing, "param is missing or the value is empty: payload")
      end
    end
  end
end
