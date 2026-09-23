# frozen_string_literal: true

# Temporary evidence harness for the admin-mailer statement-timeout fix (not committed).
require "spec_helper"

describe AdminMailer do
  describe "#chargeback_notify" do
    let!(:purchase) { create(:purchase) }
    let!(:dispute) { create(:dispute_formalized, purchase:) }

    def write_email(path, expect_timeout:)
      if expect_timeout
        allow(WithMaxExecutionTime).to receive(:timeout_queries)
          .and_raise(WithMaxExecutionTime::QueryTimeoutError.new("maximum statement execution time exceeded"))
      end
      mail = described_class.chargeback_notify(dispute.id)
      File.write(path, mail.body.encoded)
      puts "WROTE #{path}"
    end

    it "renders the email with the ratio when the aggregate is computable" do
      write_email("/tmp/1qq-mail-normal.html", expect_timeout: false)
      puts "NORMAL_BODY=#{File.read("/tmp/1qq-mail-normal.html").lines.grep(/Lost Chargebacks/).inspect}"
      expect(File.read("/tmp/1qq-mail-normal.html")).to include("Lost Chargebacks:")
    end

    it "renders the email with the ratio reported unavailable when the aggregate times out" do
      write_email("/tmp/1qq-mail-unavailable.html", expect_timeout: true)
      puts "UNAVAILABLE_BODY=#{File.read("/tmp/1qq-mail-unavailable.html").lines.grep(/Lost Chargebacks/).inspect}"
      expect(File.read("/tmp/1qq-mail-unavailable.html")).to include("Lost Chargebacks: unavailable")
    end
  end
end
