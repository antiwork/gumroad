# frozen_string_literal: true

require "spec_helper"

describe Purchases::RefundRequestsController do
  render_views

  let(:purchase) { create(:purchase) }
  let(:seller) { purchase.seller }
  let(:token) { purchase.secure_external_id(scope: described_class::SECURE_ID_SCOPE, expires_at: 6.months.from_now) }

  before do
    Feature.activate_user(:buyer_refund_requests, seller)
  end

  describe "GET show" do
    it "renders the request form for an eligible purchase with no-store headers" do
      get :show, params: { purchase_id: token }

      expect(response).to be_successful
      expect(response.body).to include("Request a refund")
      expect(response.body).to include("Send refund request")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    end

    it "404s when the flag is off for the seller" do
      Feature.deactivate_user(:buyer_refund_requests, seller)

      expect { get :show, params: { purchase_id: token } }.to raise_error(ActionController::RoutingError)
    end

    it "404s for an invalid token" do
      expect { get :show, params: { purchase_id: "garbage" } }.to raise_error(ActionController::RoutingError)
    end

    it "404s for an expired token" do
      expired_token = purchase.secure_external_id(scope: described_class::SECURE_ID_SCOPE, expires_at: 1.minute.ago)

      expect { get :show, params: { purchase_id: expired_token } }.to raise_error(ActionController::RoutingError)
    end

    it "404s for a token with the wrong scope" do
      wrong_scope_token = purchase.secure_external_id(scope: "unsubscribe")

      expect { get :show, params: { purchase_id: wrong_scope_token } }.to raise_error(ActionController::RoutingError)
    end

    it "shows the current state instead of the form when a request exists" do
      create(:purchase_refund_request, purchase:, seller_notified_at: Time.current, support_notified_at: Time.current)

      get :show, params: { purchase_id: token }

      expect(response.body).to include("Your refund request has been sent to the creator")
      expect(response.body).not_to include("Send refund request")
    end

    it "re-enqueues the notify worker when notifications are still owed" do
      request = create(:purchase_refund_request, purchase:, seller_notified_at: nil, support_notified_at: Time.current)

      expect do
        get :show, params: { purchase_id: token }
      end.to change(PurchaseRefundRequests::NotifyWorker.jobs, :size).by(1)
      expect(PurchaseRefundRequests::NotifyWorker.jobs.last["args"]).to eq([request.id])
    end

    it "does not re-enqueue when notifications were delivered" do
      create(:purchase_refund_request, purchase:, seller_notified_at: Time.current, support_notified_at: Time.current)

      expect do
        get :show, params: { purchase_id: token }
      end.not_to change(PurchaseRefundRequests::NotifyWorker.jobs, :size)
    end

    it "explains ineligibility for a refunded purchase" do
      purchase.update!(stripe_refunded: true)

      get :show, params: { purchase_id: token }

      expect(response.body).to include("isn't eligible")
      expect(response.body).not_to include("Send refund request")
    end
  end

  describe "POST create" do
    it "creates the request and enqueues the notify worker and escalation exactly once" do
      expect do
        post :create, params: { purchase_id: token, reason: "not_as_described", message: "Files are corrupted." }
      end.to change(PurchaseRefundRequest, :count).by(1)
        .and change(PurchaseRefundRequests::NotifyWorker.jobs, :size).by(1)
        .and change(PurchaseRefundRequests::EscalateWorker.jobs, :size).by(1)

      request = PurchaseRefundRequest.last
      expect(request.purchase).to eq(purchase)
      expect(request.email).to eq(purchase.email)
      expect(request.reason).to eq("not_as_described")
      expect(request.message).to eq("Files are corrupted.")
      expect(request.state).to eq("requested")
      expect(request.seller_notified_at).to be_nil

      expect(PurchaseRefundRequests::NotifyWorker.jobs.last["args"]).to eq([request.id])
      expect(response).to redirect_to(purchase_refund_request_path(token))
    end

    it "returns the existing open request without enqueueing anything" do
      existing = create(:purchase_refund_request, purchase:)
      PurchaseRefundRequests::NotifyWorker.jobs.clear

      expect do
        post :create, params: { purchase_id: token, reason: "other" }
      end.to not_change(PurchaseRefundRequest, :count)
        .and not_change(PurchaseRefundRequests::NotifyWorker.jobs, :size)

      expect(response).to redirect_to(purchase_refund_request_path(token))
      expect(PurchaseRefundRequest.open_for(purchase)).to eq(existing)
    end

    it "rejects a refunded purchase without creating anything" do
      purchase.update!(stripe_refunded: true)

      expect do
        post :create, params: { purchase_id: token, reason: "not_as_described" }
      end.to not_change(PurchaseRefundRequest, :count)
        .and not_change(PurchaseRefundRequests::NotifyWorker.jobs, :size)

      expect(response.body).to include("isn't eligible")
    end

    it "rejects a purchase whose previous request was declined" do
      create(:purchase_refund_request, purchase:, state: "declined")

      expect do
        post :create, params: { purchase_id: token, reason: "other" }
      end.not_to change(PurchaseRefundRequest, :count)

      expect(response.body).to include("The creator declined this refund request")
      expect(response.body).not_to include("Send refund request")
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:buyer_refund_requests, seller)

      expect do
        post :create, params: { purchase_id: token, reason: "not_as_described" }
      end.to raise_error(ActionController::RoutingError)
      expect(PurchaseRefundRequest.count).to eq(0)
    end

    it "re-renders the form when no valid reason is given" do
      expect do
        post :create, params: { purchase_id: token, reason: "nonsense" }
      end.not_to change(PurchaseRefundRequest, :count)

      expect(response).to redirect_to(purchase_refund_request_path(token))
    end

    it "truncates the message to the cap" do
      post :create, params: { purchase_id: token, reason: "other", message: "a" * 3000 }

      expect(PurchaseRefundRequest.last.message.length).to eq(PurchaseRefundRequest::MAX_MESSAGE_LENGTH)
    end
  end
end
