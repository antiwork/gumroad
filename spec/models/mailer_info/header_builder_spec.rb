# frozen_string_literal: true

require "spec_helper"

RSpec.describe MailerInfo::HeaderBuilder do
  let(:mailer_class) { "CustomerMailer" }
  let(:mailer_method) { "test_email" }
  let(:mailer_args) { ["test@example.com"] }

  describe ".perform" do
    it "delegates to instance" do
      instance = instance_double(described_class)
      allow(described_class).to receive(:new).and_return(instance)
      allow(instance).to receive(:perform).and_return({ "test" => "value" })

      described_class.perform(
        mailer_class:,
        mailer_method:,
        mailer_args:,
        email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID
      )

      expect(instance).to have_received(:perform)
    end
  end

  describe "#build_for_sendgrid" do
    let(:builder) do
      described_class.new(
        mailer_class:,
        mailer_method:,
        mailer_args:,
        email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID
      )
    end

    it "builds basic headers" do
      headers = builder.build_for_sendgrid

      smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
      expect(smtpapi["environment"]).to eq(Rails.env)
      expect(smtpapi["category"]).to eq([mailer_class, "#{mailer_class}.#{mailer_method}"])
      expect(smtpapi["unique_args"]["mailer_class"]).to eq(mailer_class)
      expect(smtpapi["unique_args"]["mailer_method"]).to eq(mailer_method)
    end

    context "with receipt email" do
      let(:mailer_method) { SendgridEventInfo::RECEIPT_MAILER_METHOD }
      let(:purchase) { create(:purchase) }
      let(:mailer_args) { [purchase.id, nil] }

      it "includes purchase id" do
        headers = builder.build_for_sendgrid
        smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
        expect(smtpapi["unique_args"]["purchase_id"]).to eq(purchase.id)
      end
    end

    context "with preorder receipt email" do
      let(:mailer_method) { SendgridEventInfo::PREORDER_RECEIPT_MAILER_METHOD }
      let(:preorder) { create(:preorder) }
      let(:mailer_args) { [preorder.id] }

      before do
        allow_any_instance_of(Preorder).to receive(:authorization_purchase).and_return(create(:purchase))
      end

      it "includes authorization purchase id" do
        headers = builder.build_for_sendgrid
        smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
        expect(smtpapi["unique_args"]["purchase_id"]).to eq(preorder.authorization_purchase.id)
      end
    end

    context "with abandoned cart email" do
      let(:mailer_method) { EmailEventInfo::ABANDONED_CART_MAILER_METHOD }
      let(:workflow_ids) { { "1" => "test" } }
      let(:mailer_args) { ["test@example.com", workflow_ids] }

      it "includes workflow ids" do
        headers = builder.build_for_sendgrid
        smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
        expect(smtpapi["unique_args"]["workflow_ids"]).to be_nil # SendGrid doesn't use workflow_ids
        expect(smtpapi["unique_args"]["mailer_args"]).to eq(mailer_args.inspect)
        expect(smtpapi["unique_args"]["mailer_class"]).to eq(mailer_class)
        expect(smtpapi["unique_args"]["mailer_method"]).to eq(mailer_method)
      end
    end
  end

  describe "#build_for_resend" do
    let(:builder) do
      described_class.new(
        mailer_class:,
        mailer_method:,
        mailer_args:,
        email_provider: MailerInfo::EMAIL_PROVIDER_RESEND
      )
    end

    it "builds basic headers" do
      headers = builder.build_for_resend

      expect(headers[MailerInfo.header_name(:email_provider)]).to eq(MailerInfo::EMAIL_PROVIDER_RESEND)

      encrypted_env = headers[MailerInfo.header_name(:environment)]
      expect(MailerInfo.decrypt(encrypted_env)).to eq(Rails.env)

      encrypted_class = headers[MailerInfo.header_name(:mailer_class)]
      expect(MailerInfo.decrypt(encrypted_class)).to eq(mailer_class)

      encrypted_method = headers[MailerInfo.header_name(:mailer_method)]
      expect(MailerInfo.decrypt(encrypted_method)).to eq(mailer_method)

      encrypted_category = headers[MailerInfo.header_name(:category)]
      expect(JSON.parse(MailerInfo.decrypt(encrypted_category))).to eq([mailer_class, "#{mailer_class}.#{mailer_method}"])
    end

    context "with receipt email" do
      let(:mailer_method) { SendgridEventInfo::RECEIPT_MAILER_METHOD }
      let(:purchase) { create(:purchase) }
      let(:mailer_args) { [purchase.id, nil] }

      it "includes purchase id" do
        headers = builder.build_for_resend
        encrypted_id = headers[MailerInfo.header_name(:purchase_id)]
        expect(MailerInfo.decrypt(encrypted_id)).to eq(purchase.id.to_s)
      end
    end

    context "with preorder receipt email" do
      let(:mailer_method) { SendgridEventInfo::PREORDER_RECEIPT_MAILER_METHOD }
      let(:preorder) { create(:preorder) }
      let(:mailer_args) { [preorder.id] }

      before do
        allow_any_instance_of(Preorder).to receive(:authorization_purchase).and_return(create(:purchase))
      end

      it "includes authorization purchase id" do
        headers = builder.build_for_resend
        encrypted_id = headers[MailerInfo.header_name(:purchase_id)]
        expect(MailerInfo.decrypt(encrypted_id)).to eq(preorder.authorization_purchase.id.to_s)
      end
    end

    context "with abandoned cart email" do
      let(:mailer_method) { EmailEventInfo::ABANDONED_CART_MAILER_METHOD }
      let(:workflow_ids) { { "1" => "test" } }
      let(:mailer_args) { ["test@example.com", workflow_ids] }

      it "includes workflow ids" do
        headers = builder.build_for_resend
        encrypted_ids = headers[MailerInfo.header_name(:workflow_ids)]
        expect(MailerInfo.decrypt(encrypted_ids)).to eq(workflow_ids.keys.to_json)
      end

      it "raises error with unexpected args" do
        expect do
          described_class.new(
            mailer_class:,
            mailer_method:,
            mailer_args: ["test@example.com"],
            email_provider: MailerInfo::EMAIL_PROVIDER_RESEND
          ).build_for_resend
        end.to raise_error(ArgumentError, /Abandoned cart email event has unexpected mailer_args size/)
      end
    end
  end

  describe "#truncated_mailer_args" do
    let(:builder) do
      described_class.new(
        mailer_class:,
        mailer_method:,
        mailer_args: ["a" * 30, 123, { key: "value" }],
        email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID
      )
    end

    it "truncates string arguments to 20 chars" do
      expect(builder.truncated_mailer_args).to eq(["a" * 20, 123, { key: "value" }])
    end
  end
end
