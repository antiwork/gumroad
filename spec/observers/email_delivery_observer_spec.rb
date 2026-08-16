# frozen_string_literal: true

require "spec_helper"

describe EmailDeliveryObserver do
  describe ".delivered_email" do
    let(:message) { instance_double(Mail::Message) }

    before do
      allow(EmailDeliveryObserver::HandleCustomerEmailInfo).to receive(:perform).with(message).and_return(true)
    end

    it "calls the customer email info handler" do
      expect(EmailDeliveryObserver::HandleCustomerEmailInfo).to receive(:perform).with(message).and_return(true)
      EmailDeliveryObserver.delivered_email(message)
    end
  end
end
