# frozen_string_literal: true

require "test_helper"

class RescueSmtpErrorsTest < ActionMailer::TestCase
  self.described_class = RescueSmtpErrors



  context_ RescueSmtpErrors do
    let(:mailer_class) do
      Class.new(ActionMailer::Base) do
        include RescueSmtpErrors

        def welcome
          # We need a body to not render views
          mail(from: "foo@bar.com", body: "")
        end
      end
    end

  context_ "rescue from SMTP exceptions" do
      let(:user) { create(:user) }

  context_ "when exception class is ArgumentError" do
  test "raises on messages other than blank-to-address" do
          allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(ArgumentError)

          expect { mailer_class.welcome.deliver_now }.to raise_error(ArgumentError)
        end

  test "does not raise on blank smtp to address" do
          allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(ArgumentError.new("SMTP To address may not be blank"))

          expect { mailer_class.welcome.deliver_now }.not_to raise_error
        end
      end

  test "does not raise Net::SMTPSyntaxError" do
        allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(Net::SMTPSyntaxError.new(nil))

        expect { mailer_class.welcome.deliver_now }.not_to raise_error
      end

  test "does not raise Net::SMTPAuthenticationError" do
        allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(Net::SMTPAuthenticationError.new(nil))

        expect { mailer_class.welcome.deliver_now }.not_to raise_error
      end
    end
  end
end
