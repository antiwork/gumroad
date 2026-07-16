# frozen_string_literal: true

require "spec_helper"

describe FailedRefundException do
  it "allows only one exception record per refund" do
    failed_refund_exception = create(:failed_refund_exception)

    duplicate = build(:failed_refund_exception, refund: failed_refund_exception.refund)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:refund_id]).to be_present
  end

  it "separates deliverable, delivery-exhausted, and overdue exceptions" do
    deliverable = create(:failed_refund_exception)
    exhausted = create(:failed_refund_exception, notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES)
    overdue = create(:failed_refund_exception, due_at: 1.hour.ago, notification_sent_at: Time.current)
    create(:failed_refund_exception, notification_sent_at: Time.current) # delivered, on time
    create(:failed_refund_exception, state: "resolved", due_at: 1.hour.ago, resolved_at: Time.current)

    expect(FailedRefundException.notification_deliverable).to contain_exactly(deliverable)
    expect(FailedRefundException.delivery_exhausted).to contain_exactly(exhausted)
    expect(FailedRefundException.overdue).to contain_exactly(overdue)
  end

  it "uses a separately configured notification room for a free-form owner" do
    allow(GlobalConfig).to receive(:get)
      .with("FAILED_REFUND_EXCEPTION_NOTIFICATION_ROOM", "refund-taskforce")
      .and_return("risk")

    expect(described_class.default_notification_room(owner: "refund-taskforce")).to eq("risk")
  end

  it "rejects a notification room that does not exist" do
    allow(GlobalConfig).to receive(:get)
      .with("FAILED_REFUND_EXCEPTION_NOTIFICATION_ROOM", "refund-taskforce")
      .and_return("unknown-room")

    expect { described_class.default_notification_room(owner: "refund-taskforce") }
      .to raise_error(ArgumentError, /Unknown failed-refund notification room/)
  end

  it "records a resolution and closes the exception" do
    failed_refund_exception = create(:failed_refund_exception)

    freeze_time do
      failed_refund_exception.resolve!(resolution: "Buyer re-refunded to the original payment method")

      expect(failed_refund_exception).to have_attributes(
        state: "resolved",
        resolution: "Buyer re-refunded to the original payment method",
        resolved_at: Time.current
      )
    end
  end
end
