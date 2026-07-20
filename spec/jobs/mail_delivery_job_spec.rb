# frozen_string_literal: true

require "spec_helper"

describe MailDeliveryJob do
  it "is configured as the delivery job for deliver_later" do
    expect(ActionMailer::Base.delivery_job).to eq(described_class)
  end

  describe "transient SMTP timeout handling" do
    let(:job) { described_class.new("CustomerMailer", "grouped_receipt", "deliver_now") }

    [Net::ReadTimeout, Net::OpenTimeout].each do |error_class|
      context "when delivery raises #{error_class}" do
        before do
          allow(job).to receive(:perform).and_raise(error_class)
        end

        it "re-enqueues the job for a retry instead of raising" do
          expect(job).to receive(:retry_job)
          expect { job.perform_now }.not_to raise_error
        end

        it "re-raises once retry attempts are exhausted" do
          job.exception_executions = { "[Net::OpenTimeout, Net::ReadTimeout]" => 10 }

          expect(job).not_to receive(:retry_job)
          expect { job.perform_now }.to raise_error(error_class)
        end
      end
    end

    it "does not swallow non-timeout delivery errors" do
      allow(job).to receive(:perform).and_raise(SendGridApiResponseError)

      expect(job).not_to receive(:retry_job)
      expect { job.perform_now }.to raise_error(SendGridApiResponseError)
    end
  end
end
