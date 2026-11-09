# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Purchases::RefundRequestsController, type: :controller, inertia: true do
  let(:purchase) { create(:purchase) }
  let(:seller) { purchase.seller }
  let(:token) { purchase.secure_external_id(scope: PurchaseRefundRequest::SECURE_ID_SCOPE, expires_at: PurchaseRefundRequest::LINK_EXPIRY.from_now) }

  before do
    Feature.activate_user(:buyer_refund_requests, seller)
  end

  describe "GET show" do
    it "renders the request form for an eligible purchase with no-store headers" do
      get :show, params: { purchase_id: token }

      expect(response).to be_successful
      expect(inertia.component).to eq("Purchases/RefundRequest/Show")
      expect(inertia.props.slice(:purchase_route_id, :product_name, :refund_request, :ineligibility)).to eq(
        purchase_route_id: token,
        product_name: purchase.link.name,
        refund_request: nil,
        ineligibility: nil,
      )
      expect(inertia.props[:reasons].map { _1[:value] }).to eq(PurchaseRefundRequest::REASONS)
      expect(inertia.props[:seller_name]).to eq(seller.name_or_username)
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
      expired_token = purchase.secure_external_id(scope: PurchaseRefundRequest::SECURE_ID_SCOPE, expires_at: 1.minute.ago)

      expect { get :show, params: { purchase_id: expired_token } }.to raise_error(ActionController::RoutingError)
    end

    it "404s for a token with the wrong scope" do
      wrong_scope_token = purchase.secure_external_id(scope: "unsubscribe")

      expect { get :show, params: { purchase_id: wrong_scope_token } }.to raise_error(ActionController::RoutingError)
    end

    it "shows the current request" do
      create(:purchase_refund_request, purchase:, reason: "other")

      get :show, params: { purchase_id: token }

      expect(inertia.props[:refund_request]).to eq(status: "requested", email: purchase.email, reason_label: "Something else")
    end

    it "reads the status from the purchase" do
      create(:purchase_refund_request, purchase:, escalated_at: Time.current)
      purchase.update_column(:stripe_refunded, true)

      get :show, params: { purchase_id: token }

      expect(inertia.props[:refund_request][:status]).to eq("refunded")
    end

    it "explains ineligibility for a partly refunded purchase" do
      purchase.update!(stripe_partially_refunded: true)

      get :show, params: { purchase_id: token }

      expect(inertia.props[:ineligibility]).to eq("partially_refunded")
    end

    it "tells a buyer who disputed after a partial refund that the dispute closed the request" do
      create(:purchase_refund_request, purchase:)
      purchase.update_columns(stripe_partially_refunded: true, chargeback_date: Time.current)

      get :show, params: { purchase_id: token }

      expect(inertia.props[:refund_request][:status]).to eq("disputed")
    end

    it "gives the deadline a request sent now would get" do
      travel_to(Time.utc(2026, 11, 6, 12)) do # Friday
        get :show, params: { purchase_id: token }
      end

      expect(inertia.props[:respond_by]).to eq("Tuesday, November 10")
    end

    it "gives the date the refund window ended" do
      create(:purchase_refund_policy, purchase:, max_refund_period_in_days: 30)
      purchase.update_column(:created_at, Time.utc(2026, 9, 9, 12))

      get :show, params: { purchase_id: token }

      expect(inertia.props[:ineligibility]).to eq("outside_window")
      expect(inertia.props[:refund_window_ended_on]).to eq("Friday, October 9")
    end

    it "explains ineligibility for a refunded purchase" do
      purchase.update!(stripe_refunded: true)

      get :show, params: { purchase_id: token }

      expect(inertia.props[:ineligibility]).to eq("refunded")
    end
  end

  describe "POST create" do
    it "creates the request and queues the seller and buyer emails" do
      expect do
        post :create, params: { purchase_id: token, reason: "not_as_described", message: "Files are corrupted." }
      end.to change(PurchaseRefundRequest, :count).by(1)
        .and have_enqueued_mail(ContactingCreatorMailer, :refund_requested)
        .and have_enqueued_mail(CustomerLowPriorityMailer, :refund_request_received)

      request = PurchaseRefundRequest.last
      expect(request.purchase).to eq(purchase)
      expect(request.email).to eq(purchase.email)
      expect(request.reason).to eq("not_as_described")
      expect(request.message).to eq("Files are corrupted.")
      expect(response).to redirect_to(purchase_refund_request_path(token))
    end

    it "keeps the existing request on a second submit" do
      existing = create(:purchase_refund_request, purchase:)

      expect do
        post :create, params: { purchase_id: token, reason: "other" }
      end.to not_change(PurchaseRefundRequest, :count)
        .and not_have_enqueued_mail(ContactingCreatorMailer, :refund_requested)

      expect(response).to redirect_to(purchase_refund_request_path(token))
      expect(PurchaseRefundRequest.find_by(purchase_id: purchase.id)).to eq(existing)
    end

    it "rejects a refunded purchase without creating anything" do
      purchase.update!(stripe_refunded: true)

      expect do
        post :create, params: { purchase_id: token, reason: "not_as_described" }
      end.not_to change(PurchaseRefundRequest, :count)

      expect(response).to redirect_to(purchase_refund_request_path(token))
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:buyer_refund_requests, seller)

      expect do
        post :create, params: { purchase_id: token, reason: "not_as_described" }
      end.to raise_error(ActionController::RoutingError)
      expect(PurchaseRefundRequest.count).to eq(0)
    end

    it "redirects back with an alert when no valid reason is given" do
      expect do
        post :create, params: { purchase_id: token, reason: "nonsense" }
      end.not_to change(PurchaseRefundRequest, :count)

      expect(response).to redirect_to(purchase_refund_request_path(token))
      expect(flash[:alert]).to eq("Please select a reason for your refund request.")
    end

    it "truncates the message to the cap" do
      post :create, params: { purchase_id: token, reason: "other", message: "a" * 3000 }

      expect(PurchaseRefundRequest.last.message.length).to eq(PurchaseRefundRequest::MAX_MESSAGE_LENGTH)
    end
  end
end
