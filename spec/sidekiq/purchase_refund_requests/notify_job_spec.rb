# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequests::NotifyJob do
  let(:purchase) { create(:purchase) }
  let(:refund_request) { create(:purchase_refund_request, purchase:, message: "The files were corrupted.") }

  before do
    Feature.activate_user(:buyer_refund_requests, purchase.seller)
  end

  it "delivers the seller, buyer and support notifications and stamps them" do
    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(3)

    refund_request.reload
    expect(refund_request.seller_notified_at).to be_present
    expect(refund_request.buyer_notified_at).to be_present
    expect(refund_request.support_notified_at).to be_present

    seller_mail = ActionMailer::Base.deliveries.find { |mail| mail.to == [purchase.seller.email] }
    expect(seller_mail.subject).to eq("Refund requested for #{purchase.link.name} (#{purchase.formatted_display_price})")
    buyer_mail = ActionMailer::Base.deliveries.find { |mail| mail.to == [refund_request.email] }
    expect(buyer_mail.subject).to eq("Your refund request for #{purchase.link.name} was sent to #{purchase.seller.name_or_username}")
  end

  it "sends the buyer the escalation notice once, and no confirmation, after escalation" do
    refund_request.update_columns(state: "escalated", created_at: 5.days.ago, seller_notified_at: 5.days.ago)

    described_class.new.perform(refund_request.id)
    described_class.new.perform(refund_request.id)

    expect(ActionMailer::Base.deliveries.map(&:subject)).to eq(["Gumroad support is reviewing your refund request for #{purchase.link.name}"])
    expect(refund_request.reload.buyer_escalation_notified_at).to be_present
    expect(refund_request.buyer_notified_at).to be_nil
  end

  it "is idempotent: a second run delivers nothing" do
    described_class.new.perform(refund_request.id)

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "holds no transaction or row lock while the mail is delivered" do
    refund_request
    baseline = ActiveRecord::Base.connection.open_transactions
    open_during_delivery = []
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_wrap_original do |original, *args|
      open_during_delivery << ActiveRecord::Base.connection.open_transactions
      original.call(*args)
    end

    described_class.new.perform(refund_request.id)

    expect(open_during_delivery).to eq([baseline] * 3)
    expect(refund_request.reload.seller_notified_at).to be_present
  end

  it "leaves the seller notification owed when the mailer skips the send" do
    purchase.seller.update_columns(email: "not-an-email", unconfirmed_email: nil)

    described_class.new.perform(refund_request.id)

    expect(refund_request.reload.seller_notified_at).to be_nil
    expect(refund_request.support_notified_at).to be_present
    expect(ActionMailer::Base.deliveries.last.text_part.decoded.squish).to include("the seller could not be emailed, so contact them directly")
  end

  it "raises without stamping when the mail server rejects the email" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))

    expect { described_class.new.perform(refund_request.id) }.to raise_error(Net::SMTPFatalError)
    expect(refund_request.reload.seller_notified_at).to be_nil
  end

  it "delivers only the missing notification on retry after a partial failure" do
    refund_request.update_columns(seller_notified_at: Time.current, buyer_notified_at: Time.current)

    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(refund_request.reload.support_notified_at).to be_present
  end

  it "does nothing when the flag was turned off after enqueue" do
    Feature.deactivate_user(:buyer_refund_requests, purchase.seller)

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
    expect(refund_request.reload.seller_notified_at).to be_nil
  end

  it "still sends an owed seller email after the request escalated" do
    refund_request.update_columns(state: "escalated", open_key: nil, support_notified_at: Time.current, buyer_escalation_notified_at: Time.current)

    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(ActionMailer::Base.deliveries.last.to).to eq([purchase.seller.email])
    expect(refund_request.reload.seller_notified_at).to be_present
  end

  it "sends only the seller email past the deadline, since the escalation email is support's notice" do
    refund_request.update_columns(created_at: 5.days.ago)

    described_class.new.perform(refund_request.id)

    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([[purchase.seller.email]])
    expect(refund_request.reload.support_notified_at).to be_nil
    expect(refund_request.notifications_pending?).to eq(false)
  end

  context "when the refund/chargeback sync missed an escalated request" do
    before do
      refund_request.update_columns(state: "escalated", open_key: nil, created_at: 5.days.ago, support_notified_at: 5.days.ago,
                                    buyer_escalation_notified_at: 5.days.ago)
    end

    it "closes it as refunded instead of emailing the seller about a refunded purchase" do
      purchase.update_column(:stripe_refunded, true)

      expect do
        described_class.new.perform(refund_request.id)
      end.not_to change { ActionMailer::Base.deliveries.count }
      expect(refund_request.reload.state).to eq("refunded")
      expect(refund_request.seller_notified_at).to be_nil
    end

    it "closes it as expired instead of emailing the seller about a charged-back purchase" do
      purchase.update_column(:chargeback_date, Time.current)

      expect do
        described_class.new.perform(refund_request.id)
      end.not_to change { ActionMailer::Base.deliveries.count }
      expect(refund_request.reload.state).to eq("expired")
    end

    it "still sends the seller email after a partial refund" do
      purchase.update_column(:stripe_partially_refunded, true)

      expect do
        described_class.new.perform(refund_request.id)
      end.to change { ActionMailer::Base.deliveries.count }.by(1)
      expect(refund_request.reload.state).to eq("escalated")
    end
  end

  it "does nothing for a closed request" do
    refund_request.update!(state: "expired")

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "settles a malformed buyer address instead of retrying it" do
    refund_request.update_column(:email, "not-an-email")

    described_class.new.perform(refund_request.id)

    expect(ActionMailer::Base.deliveries.flat_map(&:to)).not_to include("not-an-email")
    expect(refund_request.reload.buyer_notified_at).to be_present
    expect(refund_request.notifications_pending?).to eq(false)
  end

  it "still sends the buyer confirmation when the mail server rejects the seller email" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_wrap_original do |original, *args|
      raise Net::SMTPFatalError.new("550 rejected") if original.receiver.to == [purchase.seller.email]

      original.call(*args)
    end

    expect { described_class.new.perform(refund_request.id) }.to raise_error(Net::SMTPFatalError)
    expect(refund_request.reload.buyer_notified_at).to be_present
    expect(refund_request.seller_notified_at).to be_nil
  end

  it "does nothing for a deleted request" do
    expect do
      described_class.new.perform(-1)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end

  context "with the unique lock enabled" do
    around do |example|
      SidekiqUniqueJobs.use_config(enabled: true) { example.run }
    end

    it "drops a re-push while the create-time job for the same request is still queued" do
      refund_request
      expect(described_class.jobs.map { _1["args"] }).to eq([[refund_request.id]])

      expect(described_class.perform_async(refund_request.id)).to be_nil
      expect(described_class.jobs.size).to eq(1)
    end
  end
end
