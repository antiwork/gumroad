# frozen_string_literal: true

require "spec_helper"

describe CreatorContactingCustomersEmailInfo do
  describe "state transitions" do
    it "transitions to sent" do
      email_info = create(:creator_contacting_customers_email_info)
      email_info.update_attribute(:delivered_at, Time.current)
      expect(email_info.email_name).to eq "purchase_installment"
      email_info.mark_sent!
      expect(email_info.reload.state).to eq("sent")
      expect(email_info.reload.sent_at).to be_present
      expect(email_info.reload.delivered_at).to be_nil
    end

    it "transitions to delivered" do
      email_info = create(:creator_contacting_customers_email_info_sent)
      expect(email_info.sent_at).to be_present
      expect(email_info.delivered_at).to be_nil
      expect(email_info.opened_at).to be_nil
      email_info.mark_delivered!
      expect(email_info.reload.state).to eq("delivered")
      expect(email_info.reload.delivered_at).to be_present
    end

    it "transitions to opened" do
      email_info = create(:creator_contacting_customers_email_info_delivered)
      expect(email_info.sent_at).to be_present
      expect(email_info.delivered_at).to be_present
      expect(email_info.opened_at).to be_nil
      email_info.mark_opened!
      expect(email_info.reload.state).to eq("opened")
      expect(email_info.reload.opened_at).to be_present
    end

    it "transitions to bounced and then sent" do
      email_info = create(:creator_contacting_customers_email_info_sent)
      email_info.mark_bounced!
      expect(email_info.reload.state).to eq("bounced")
      expect(email_info.reload.sent_at).to be_present
      email_info.mark_sent!
      expect(email_info.reload.state).to eq("sent")
      expect(email_info.reload.sent_at).to be_present
    end
  end

  describe "#mark_bounced!" do
    it "attempts to unsubscribe the buyer of the purchase" do
      email_info = create(:creator_contacting_customers_email_info_sent)
      expect(email_info.purchase).to receive(:unsubscribe_buyer).and_call_original

      email_info.mark_bounced!
    end
  end
end
