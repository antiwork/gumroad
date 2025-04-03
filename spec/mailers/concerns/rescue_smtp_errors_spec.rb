# frozen_string_literal: true

require "spec_helper"

describe RescueSmtpErrors do
  let(:mailer_class) do
    Class.new(ActionMailer::Base) do
      include RescueSmtpErrors

      def welcome
        # We need a body to not render views
        mail(from: "foo@bar.com", body: "")
      end
    end
  end

  describe "rescue from SMTP exceptions" do
    let(:user) { create(:user) }

    context "when exception class is ArgumentError" do
      it "raises on messages other than blank-to-address" do
        allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(ArgumentError)

        expect { mailer_class.welcome.deliver_now }.to raise_error(ArgumentError)
      end

      it "does not raise on blank smtp to address" do
        allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(ArgumentError.new("SMTP To address may not be blank"))

        expect { mailer_class.welcome.deliver_now }.to_not raise_error
      end
    end

    it "does not raise Net::SMTPSyntaxError" do
      allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(Net::SMTPSyntaxError.new(nil))

      expect { mailer_class.welcome.deliver_now }.to_not raise_error
    end

    it "does not raise Net::SMTPAuthenticationError" do
      allow_any_instance_of(mailer_class).to receive(:welcome).and_raise(Net::SMTPAuthenticationError.new(nil))

      expect { mailer_class.welcome.deliver_now }.to_not raise_error
    end
  end
end
