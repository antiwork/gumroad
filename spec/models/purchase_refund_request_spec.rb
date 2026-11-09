# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequest do
  let(:purchase) { create(:purchase) }

  before { Feature.activate_user(:buyer_refund_requests, purchase.seller) }

  describe "validations" do
    it "caps the message length" do
      request = build(:purchase_refund_request, purchase:, message: "a" * (described_class::MAX_MESSAGE_LENGTH + 1))
      expect(request).not_to be_valid
    end

    it "rejects unknown reasons" do
      expect(build(:purchase_refund_request, purchase:, reason: "because")).not_to be_valid
    end

    it "allows one request per purchase, at the database" do
      create(:purchase_refund_request, purchase:)

      expect { build(:purchase_refund_request, purchase:).save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "on create" do
    it "queues the seller email and the buyer confirmation" do
      expect do
        create(:purchase_refund_request, purchase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :refund_requested)
        .and have_enqueued_mail(CustomerLowPriorityMailer, :refund_request_received)
    end

    it "never logs the buyer's free-text message" do
      logged = []
      allow(Rails.logger).to receive(:info) { |line| logged << line.to_s }

      create(:purchase_refund_request, purchase:, message: "SECRET-BUYER-TEXT")

      expect(logged.join).to include("[PurchaseRefundRequest]")
      expect(logged.join).not_to include("SECRET-BUYER-TEXT")
    end
  end

  describe "#status" do
    let(:request) { create(:purchase_refund_request, purchase:) }

    it "follows the purchase and the escalation" do
      expect(request.status).to eq("requested")

      request.update!(escalated_at: Time.current)
      expect(request.status).to eq("escalated")

      purchase.update!(chargeback_date: Time.current)
      expect(request.reload.status).to eq("disputed")

      purchase.update!(stripe_refunded: true)
      expect(request.reload.status).to eq("refunded")
    end

    it "goes back to the request's own status when a refund is reversed" do
      purchase.update!(stripe_refunded: true)
      expect(request.status).to eq("refunded")

      purchase.update!(stripe_refunded: false)
      expect(request.reload.status).to eq("requested")
    end
  end

  describe ".escalation_candidates" do
    it "leaves out refunded, disputed, escalated, and recent requests" do
      candidate = create(:purchase_refund_request, purchase:, created_at: 3.days.ago)
      create(:purchase_refund_request, created_at: 3.days.ago).purchase.update!(stripe_refunded: true)
      create(:purchase_refund_request, created_at: 3.days.ago).purchase.update!(chargeback_date: Time.current)
      create(:purchase_refund_request, created_at: 3.days.ago, escalated_at: 1.day.ago)
      create(:purchase_refund_request)

      expect(described_class.escalation_candidates).to contain_exactly(candidate)
    end
  end

  describe "#escalation_deadline" do
    it "adds two business days, skipping weekends" do
      request = travel_to(Time.utc(2026, 11, 6, 12)) { create(:purchase_refund_request, purchase:) } # Friday

      expect(request.escalation_deadline.to_date).to eq(Date.new(2026, 11, 10)) # Tuesday
    end
  end

  describe "#escalate!" do
    let(:request) { create(:purchase_refund_request, purchase:, message: "Files are corrupted.") }

    it "emails support, marks the request escalated, and queues the buyer notice" do
      expect do
        request.escalate!
      end.to change { ActionMailer::Base.deliveries.count }.by(1)
        .and have_enqueued_mail(CustomerLowPriorityMailer, :refund_request_escalated)

      support_mail = ActionMailer::Base.deliveries.last
      expect(support_mail.text_part.decoded.squish).to include("Message: Files are corrupted.")
      expect(request.reload.escalated_at).to be_present
    end

    it "leaves the request unescalated when the mail server rejects the support email" do
      allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))

      expect { request.escalate! }.to raise_error(Net::SMTPFatalError)
      expect(request.reload.escalated_at).to be_nil
    end
  end

  describe ".ineligibility" do
    it "is nil for a completed paid purchase" do
      expect(described_class.ineligibility(purchase)).to be_nil
    end

    it "names a refunded, partly refunded, or disputed purchase" do
      purchase.update!(stripe_partially_refunded: true)
      expect(described_class.ineligibility(purchase)).to eq("partially_refunded")

      purchase.update!(chargeback_date: Time.current)
      expect(described_class.ineligibility(purchase)).to eq("disputed")

      purchase.update!(stripe_refunded: true)
      expect(described_class.ineligibility(purchase)).to eq("refunded")
    end

    it "names a purchase that was never charged" do
      free_purchase = create(:purchase, link: create(:product, price_range: "0+"), price_cents: 0,
                                        stripe_transaction_id: nil, stripe_fingerprint: nil)
      preorder = create(:preorder_authorization_purchase, stripe_transaction_id: nil)

      expect(described_class.ineligibility(free_purchase)).to eq("not_charged")
      expect(described_class.ineligibility(preorder)).to eq("not_charged")
    end

    it "names a purchase outside the refund window, with the window's end" do
      create(:purchase_refund_policy, purchase:, max_refund_period_in_days: 7)
      purchase.update!(created_at: 6.days.ago)
      expect(described_class.ineligibility(purchase)).to be_nil

      purchase.update!(created_at: 8.days.ago)
      expect(described_class.ineligibility(purchase)).to eq("outside_window")
      expect(described_class.refund_window_end(purchase)).to be_within(1.second).of(purchase.created_at + 7.days)
    end

    it "names a no-refunds policy" do
      create(:purchase_refund_policy, purchase:, title: "No refunds allowed", max_refund_period_in_days: 0)
      expect(described_class.ineligibility(purchase)).to eq("no_refunds")
    end

    it "applies the original purchase's policy to a subscription renewal, also after a plan change" do
      original = create(:membership_purchase)
      create(:purchase_refund_policy, purchase: original, title: "No refunds allowed", max_refund_period_in_days: 0)
      renewal = create(:purchase, link: original.link, subscription: original.subscription, is_original_subscription_purchase: false, email: original.email, price_cents: 5_00)
      expect(described_class.ineligibility(renewal)).to eq("no_refunds")

      original.update!(is_archived_original_subscription_purchase: true)
      create(:purchase, link: original.link, subscription: original.subscription, is_original_subscription_purchase: true, email: original.email)
      expect(original.subscription.reload.original_purchase.purchase_refund_policy).to be_nil
      expect(described_class.ineligibility(renewal.reload)).to eq("no_refunds")
    end

    it "applies the authorization purchase's policy to a released preorder's charge" do
      preorder = create(:preorder)
      authorization = create(:preorder_authorization_purchase, link: preorder.preorder_link.link, preorder:, is_preorder_authorization: true)
      create(:purchase_refund_policy, purchase: authorization, title: "No refunds allowed", max_refund_period_in_days: 0)
      charge = create(:purchase, link: authorization.link, preorder:, email: authorization.email)
      expect(described_class.ineligibility(charge)).to eq("no_refunds")
    end
  end
end
