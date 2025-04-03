# frozen_string_literal: true

require "spec_helper"

describe HandlePaypalEventWorker do
  describe "perform" do
    it "calls handle_paypal_event on HandlePaypalEventWorker" do
      id = rand(10_000)
      params = { id: }
      expect(PaypalEventHandler).to receive(:new).with(params).and_call_original
      expect_any_instance_of(PaypalEventHandler).to receive(:handle_paypal_event)
      described_class.new.perform(params)
    end
  end
end
