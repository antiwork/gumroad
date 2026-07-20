# frozen_string_literal: true

require "spec_helper"

describe MailDeliveryJob do
  it "is configured as the delivery job for deliver_later" do
    expect(ActionMailer::Base.delivery_job).to eq(described_class)
  end

  describe "transient SMTP failure handling" do
    let(:job) { described_class.new("CustomerMailer", "grouped_receipt", "deliver_now") }

    # Build a raise-able instance of each error class. The Net::SMTP response
    # errors can't be instantiated without arguments — they wrap the server's
    # reply — so we construct them from a parsed response line.
    def build_error(error_class, smtp_status_line)
      if error_class <= Net::SMTPError
        error_class.new(Net::SMTP::Response.parse(smtp_status_line))
      else
        error_class.new
      end
    end

    [Net::ReadTimeout, Net::OpenTimeout, Net::SMTPServerBusy].each do |error_class|
      context "when delivery raises #{error_class}" do
        before do
          allow(job).to receive(:perform).and_raise(build_error(error_class, "451 Internal server error. Please try again later."))
        end

        it "re-enqueues the job for a retry instead of raising" do
          expect(job).to receive(:retry_job)
          expect { job.perform_now }.not_to raise_error
        end

        it "re-raises once retry attempts are exhausted" do
          job.exception_executions = { "[Net::OpenTimeout, Net::ReadTimeout, Net::SMTPServerBusy]" => 10 }

          expect(job).not_to receive(:retry_job)
          expect { job.perform_now }.to raise_error(error_class)
        end
      end
    end

    it "does not swallow non-transient delivery errors" do
      allow(job).to receive(:perform).and_raise(SendGridApiResponseError)

      expect(job).not_to receive(:retry_job)
      expect { job.perform_now }.to raise_error(SendGridApiResponseError)
    end

    it "does not retry permanent SMTP failures (5xx)" do
      # Permanent failures are intentionally excluded from `retry_on` above.
      # They are instead handled by the RescueSmtpErrors mailer concern, which
      # logs them without retrying (retrying a permanent rejection can never
      # succeed), so the job finishes without re-enqueueing or raising.
      allow(job).to receive(:perform).and_raise(build_error(Net::SMTPFatalError, "550 mailbox unavailable"))

      expect(job).not_to receive(:retry_job)
      expect { job.perform_now }.not_to raise_error
    end
  end
end
