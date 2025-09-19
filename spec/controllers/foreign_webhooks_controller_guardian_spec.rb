# frozen_string_literal: true

require "spec_helper"

describe ForeignWebhooksController, "guardian verification webhooks" do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }
  let(:merchant_account) { create(:merchant_account, user: user, charge_processor_id: 'stripe') }

  before do
    user_compliance_info.update!(
      birthday: 17.years.ago,
      guardian_first_name: "John",
      guardian_last_name: "Doe",
      guardian_email: "guardian@example.com",
      guardian_phone: "555-1234",
      guardian_street_address: "123 Main St",
      guardian_city: "Anytown",
      guardian_state: "CA",
      guardian_zip_code: "12345",
      guardian_date_of_birth: 40.years.ago,
      guardian_stripe_tos_accepted: true,
      guardian_stripe_processing_tos_accepted: true
    )
  end

  describe "#stripe_connect" do
    context "with guardian person.updated event" do
      let(:webhook_payload) do
        {
          id: "evt_guardian_verification_123",
          type: "person.updated",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_guardian_123",
              relationship: { representative: true, owner: false, title: "Legal Guardian" },
              verification: { status: "verified" }
            },
            previous_attributes: {
              verification: { status: "pending" }
            }
          }
        }
      end

      context "with valid signature" do
        before do
          endpoint_secret = GlobalConfig.dig(:stripe_connect, :endpoint_secret)
          request.headers["Stripe-Signature"] = stripe_signature_header(webhook_payload, endpoint_secret)
        end

        it "responds successfully" do
          post :stripe_connect, params: webhook_payload, as: :json
          expect(response).to be_successful
        end

        it "enqueues HandleStripeEventWorker" do
          expect {
            post :stripe_connect, params: webhook_payload, as: :json
          }.to have_enqueued_sidekiq_job(HandleStripeEventWorker).with(webhook_payload.as_json)
        end

        it "processes the guardian verification update" do
          expect(HandleStripeEventWorker).to receive(:perform_async).with(webhook_payload.as_json)

          post :stripe_connect, params: webhook_payload, as: :json
        end
      end

      context "with invalid signature" do
        before do
          request.headers["Stripe-Signature"] = "invalid_signature"
        end

        it "responds with bad request" do
          post :stripe_connect, params: webhook_payload, as: :json
          expect(response).to be_a_bad_request
        end

        it "does not enqueue HandleStripeEventWorker" do
          expect {
            post :stripe_connect, params: webhook_payload, as: :json
          }.not_to have_enqueued_sidekiq_job(HandleStripeEventWorker)
        end
      end

      context "with missing signature" do
        it "responds with bad request" do
          post :stripe_connect, params: webhook_payload, as: :json
          expect(response).to be_a_bad_request
        end
      end
    end

    context "with guardian person.created event" do
      let(:webhook_payload) do
        {
          id: "evt_guardian_creation_123",
          type: "person.created",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_guardian_123",
              relationship: { representative: true, owner: false, title: "Legal Guardian" },
              verification: { status: "pending" }
            }
          }
        }
      end

      context "with valid signature" do
        before do
          endpoint_secret = GlobalConfig.dig(:stripe_connect, :endpoint_secret)
          request.headers["Stripe-Signature"] = stripe_signature_header(webhook_payload, endpoint_secret)
        end

        it "responds successfully" do
          post :stripe_connect, params: webhook_payload, as: :json
          expect(response).to be_successful
        end

        it "enqueues HandleStripeEventWorker" do
          expect {
            post :stripe_connect, params: webhook_payload, as: :json
          }.to have_enqueued_sidekiq_job(HandleStripeEventWorker).with(webhook_payload.as_json)
        end
      end
    end

    context "with non-guardian person event" do
      let(:webhook_payload) do
        {
          id: "evt_regular_person_123",
          type: "person.updated",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_regular_123",
              relationship: { representative: false, owner: true },
              verification: { status: "verified" }
            },
            previous_attributes: {
              verification: { status: "pending" }
            }
          }
        }
      end

      context "with valid signature" do
        before do
          endpoint_secret = GlobalConfig.dig(:stripe_connect, :endpoint_secret)
          request.headers["Stripe-Signature"] = stripe_signature_header(webhook_payload, endpoint_secret)
        end

        it "responds successfully" do
          post :stripe_connect, params: webhook_payload, as: :json
          expect(response).to be_successful
        end

        it "enqueues HandleStripeEventWorker" do
          expect {
            post :stripe_connect, params: webhook_payload, as: :json
          }.to have_enqueued_sidekiq_job(HandleStripeEventWorker).with(webhook_payload.as_json)
        end
      end
    end
  end

  describe "#stripe" do
    context "with guardian person.updated event" do
      let(:webhook_payload) do
        {
          id: "evt_guardian_verification_123",
          type: "person.updated",
          user_id: user.id,
          data: {
            object: {
              id: "person_guardian_123",
              relationship: { representative: true, owner: false, title: "Legal Guardian" },
              verification: { status: "verified" }
            },
            previous_attributes: {
              verification: { status: "pending" }
            }
          }
        }
      end

      context "with valid signature" do
        before do
          endpoint_secret = GlobalConfig.dig(:stripe, :endpoint_secret)
          request.headers["Stripe-Signature"] = stripe_signature_header(webhook_payload, endpoint_secret)
        end

        it "responds successfully" do
          post :stripe, params: webhook_payload, as: :json
          expect(response).to be_successful
        end

        it "enqueues HandleStripeEventWorker" do
          expect {
            post :stripe, params: webhook_payload, as: :json
          }.to have_enqueued_sidekiq_job(HandleStripeEventWorker).with(webhook_payload.as_json)
        end
      end
    end
  end

  private

  def stripe_signature_header(payload, secret)
    timestamp = Time.current.to_i
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload.to_json, secret)
    "t=#{timestamp},v1=#{signature}"
  end
end
