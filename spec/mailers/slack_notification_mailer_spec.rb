# frozen_string_literal: true

require "spec_helper"

RSpec.describe SlackNotificationMailer, type: :mailer do
  describe "#notification" do
    let(:room_name) { :payments }
    let(:sender) { "VAT Reporting" }
    let(:message_text) { "Quarterly report is ready" }
    let(:attachments) { [{ title: "Report URL", text: "https://example.com" }] }
    let(:slack_channel) { "accounting" }
    let(:notifications_email) { "alerts@gumroad.com" }

    before do
      allow(MailerInfo).to receive(:build_headers).and_return({})
      # Use the test domain to match the from email domain validation
      test_domain = DEFAULT_EMAIL_DOMAIN || "test.gumroad.com"
      allow(MailerInfo).to receive(:random_delivery_method_options).with(anything).and_return({
                                                                                                address: "smtp.sendgrid.net",
                                                                                                domain: test_domain
                                                                                              })
    end

    subject(:mail) do
      described_class.with(
        room_name:,
        sender:,
        message_text:,
        attachments:,
        slack_channel:,
        notifications_email:
      ).notification.deliver_now
    end

    context "when notifications_email is present" do
      it "sends to the configured notifications email" do
        expect(mail.to).to contain_exactly(notifications_email)
      end

      it "uses the noreply address as the from header" do
        expect(mail.from).to contain_exactly(ApplicationMailer::NOREPLY_EMAIL)
      end

      describe "subject formatting" do
        context "with a simple message text" do
          it "prefixes the subject with the expected format" do
            expect(mail.subject).to eq("[Gumroad Notifications][Payments] #{message_text}")
          end
        end

        context "when room_name is a string" do
          let(:room_name) { "risk_management" }

          it "titleizes the room name correctly" do
            expect(mail.subject).to eq("[Gumroad Notifications][Risk Management] #{message_text}")
          end
        end

        context "when message_text is nil" do
          let(:message_text) { nil }

          it "defaults to 'Slack notification'" do
            expect(mail.subject).to eq("[Gumroad Notifications][Payments] Slack notification")
          end
        end

        context "when message_text is empty" do
          let(:message_text) { "" }

          it "defaults to 'Slack notification'" do
            expect(mail.subject).to eq("[Gumroad Notifications][Payments] Slack notification")
          end
        end

        context "when message_text is an array" do
          let(:message_text) { ["Part 1", "Part 2", "Part 3"] }

          it "joins the array elements" do
            expect(mail.subject).to eq("[Gumroad Notifications][Payments] Part 1 Part 2 Part 3")
          end
        end

        context "when message_text is an array with nil values" do
          let(:message_text) { ["Part 1", nil, "Part 3", ""] }

          it "removes nil and empty values" do
            expect(mail.subject).to eq("[Gumroad Notifications][Payments] Part 1 Part 3")
          end
        end

        context "when message_text has extra whitespace" do
          let(:message_text) { "  Multiple   spaces   here  " }

          it "squishes whitespace" do
            expect(mail.subject).to eq("[Gumroad Notifications][Payments] Multiple spaces here")
          end
        end
      end

      describe "email body content" do
        it "renders the room name" do
          expect(mail.body.encoded).to include("Payments")
        end

        it "renders the slack channel" do
          expect(mail.body.encoded).to include("#accounting")
        end

        it "renders the sender" do
          expect(mail.body.encoded).to include(sender)
        end

        let(:html_body) { mail.html_part.body.to_s }

        it "renders the message text in the body" do
          expect(html_body).to include("<p>#{message_text}</p>")
        end

        context "when attachments are present" do
          it "lists attachments in the body" do
            expect(html_body).to include("Attachments:")
            expect(html_body).to match(/<strong>\s*Report URL\s*<\/strong>/)
            expect(html_body).to match(/<p>\s*https:\/\/example\.com\s*<\/p>/)
          end

          context "with multiple attachments" do
            let(:attachments) do
              [
                { title: "Report URL", text: "https://example.com" },
                { title: "Summary", text: "Summary text" }
              ]
            end

            it "renders all attachments" do
              attachments.each do |attachment|
                expect(html_body).to match(/<strong>\s*#{attachment[:title]}\s*<\/strong>/)
                expect(html_body).to match(/<p>\s*#{attachment[:text]}\s*<\/p>/)
              end
            end
          end
        end

        context "when attachments are not present" do
          let(:attachments) { nil }

          it "does not render attachments section" do
            expect(mail.body.encoded).not_to include("Attachments:")
          end
        end

        context "when attachments is an empty array" do
          let(:attachments) { [] }

          it "does not render attachments section" do
            expect(mail.body.encoded).not_to include("Attachments:")
          end
        end
      end
    end

    context "when notifications_email is not present" do
      let(:notifications_email) { nil }

      it "does not send email" do
        expect do
          described_class.with(
            room_name:,
            sender:,
            message_text:,
            attachments:,
            slack_channel:,
            notifications_email:
          ).notification.deliver_now rescue nil
        end.not_to change { ActionMailer::Base.deliveries.count }
      end
    end

    context "when notifications_email is empty" do
      let(:notifications_email) { "" }

      it "does not send email" do
        expect do
          described_class.with(
            room_name:,
            sender:,
            message_text:,
            attachments:,
            slack_channel:,
            notifications_email:
          ).notification.deliver_now rescue nil
        end.not_to change { ActionMailer::Base.deliveries.count }
      end
    end
  end
end
