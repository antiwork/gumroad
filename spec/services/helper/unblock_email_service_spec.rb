# frozen_string_literal: true

require "spec_helper"

describe Helper::UnblockEmailService do
  include ActionView::Helpers::TextHelper

  describe "#process" do
    let(:conversation_id) { "123" }
    let(:email_id) { "456" }
    let(:email) { "sam@example.com" }
    let(:unblock_email_service) { described_class.new(conversation_id:, email_id:, email:) }

    before do
      create(:user, email:)
      allow_any_instance_of(Helper::Client).to receive(:add_note).and_return(true)
      allow_any_instance_of(Helper::Client).to receive(:send_reply).and_return(true)
      allow_any_instance_of(Helper::Client).to receive(:close_conversation).and_return(true)
      allow_any_instance_of(EmailSuppressionManager).to receive(:unblock_email).and_return(true)
      allow_any_instance_of(EmailSuppressionManager).to receive(:reasons_for_suppression).and_return({})
      Feature.activate(:helper_unblock_emails)
    end

    it "returns nil when feature is not active" do
      Feature.deactivate(:helper_unblock_emails)

      expect(unblock_email_service.process).to be_nil
    end

    context "when email is blocked by gumroad" do
      let(:reply) do
        <<~REPLY
        Hey there,

        Happy to help today! We noticed your purchase attempts failed as they were flagged as potentially fraudulent. Don’t worry, our system can occasionally throw a false alarm.

        We have removed these blocks, so could you please try making the purchase again? In case it still fails, we recommend trying with a different browser and/or a different internet connection.

        If those attempts still don't work, feel free to write back to us and we will investigate further.

        Thanks!
        REPLY
      end

      before do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], email, nil)
      end

      context "when recent blocked purchase is present" do
        let(:blocked_ip_address) { "127.0.0.1" }
        let(:recent_blocked_purchase) { create(:purchase, email:, ip_address: blocked_ip_address) }

        before do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], blocked_ip_address, nil, expires_in: 1.month)
        end

        it "unblocks the buyer" do
          expect do
            unblock_email_service.recent_blocked_purchase = recent_blocked_purchase
            unblock_email_service.process

            expect(unblock_email_service.replied?).to eq true
          end.to change { recent_blocked_purchase.buyer_blocked? }.from(true).to(false)
        end

        context "when auto_reply_for_blocked_emails_in_helper feature is active" do
          before do
            Feature.activate(:auto_reply_for_blocked_emails_in_helper)
          end

          it "sends reply to the customer and closes the conversation" do
            expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply))
            expect_any_instance_of(Helper::Client).to receive(:close_conversation).with(conversation_id:)

            unblock_email_service.recent_blocked_purchase = recent_blocked_purchase
            unblock_email_service.process
          end
        end

        context "when auto_reply_for_blocked_emails_in_helper feature is not active" do
          it "drafts the reply" do
            expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply), draft: true, response_to: email_id)

            unblock_email_service.recent_blocked_purchase = recent_blocked_purchase
            unblock_email_service.process
          end
        end
      end

      context "when recent blocked purchase is not present" do
        before do
          Feature.activate(:auto_reply_for_blocked_emails_in_helper)
        end

        it "unblocks the email" do
          expect do
            expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply))
            expect_any_instance_of(Helper::Client).to receive(:close_conversation).with(conversation_id:)

            unblock_email_service.process
          end.to change { BlockedObject.email.find_active_object(email).present? }.from(true).to(false)
        end
      end
    end

    context "when email is suppressed by SendGrid" do
      let(:reply) do
        <<~REPLY
        Hey,

        Sorry about that! It seems our email provider stopped sending you emails after a few of them bounced.

        I’ve fixed this and you should now start receiving emails as usual. Please let us know if you don't and we'll take a closer look!

        Also, please add our email to your contacts list and ensure that you haven't accidentally marked any emails from us as spam.

        Hope this helps!
        REPLY
      end

      context "when reasons for suppressions are present" do
        before do
          reasons_for_suppression = {
            gumroad: [{ list: :bounces, reason: "Bounced reason 1" }, { list: :spam_reports, reason: "Email was reported as spam" }],
            creators: [{ list: :bounces, reason: "Bounced reason 2" }]
          }
          allow_any_instance_of(EmailSuppressionManager).to receive(:reasons_for_suppression).and_return(reasons_for_suppression)
        end

        it "adds as a note to the conversation" do
          expected_reasons = <<~REASONS.chomp
          • The email sam@example.com was suppressed in SendGrid. Subuser: gumroad, List: bounces, Reason: Bounced reason 1
          • The email sam@example.com was suppressed in SendGrid. Subuser: gumroad, List: spam_reports, Reason: Email was reported as spam
          • The email sam@example.com was suppressed in SendGrid. Subuser: creators, List: bounces, Reason: Bounced reason 2
          REASONS
          expect_any_instance_of(Helper::Client).to receive(:add_note).with(conversation_id:, message: expected_reasons)

          unblock_email_service.process
        end
      end

      context "when auto_reply_for_blocked_emails_in_helper feature is active" do
        before do
          Feature.activate(:auto_reply_for_blocked_emails_in_helper)
        end

        it "unblocks email and sends reply to the customer and closes the conversation" do
          expect_any_instance_of(EmailSuppressionManager).to receive(:unblock_email)
          expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply))
          expect_any_instance_of(Helper::Client).to receive(:close_conversation).with(conversation_id:)

          unblock_email_service.process

          expect(unblock_email_service.replied?). to eq true
        end
      end

      context "when auto_reply_for_blocked_emails_in_helper feature is not active" do
        before do
          Feature.deactivate(:auto_reply_for_blocked_emails_in_helper)
        end

        it "unblocks email and drafts the reply" do
          expect_any_instance_of(EmailSuppressionManager).to receive(:unblock_email)
          expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply), draft: true, response_to: email_id)

          unblock_email_service.process

          expect(unblock_email_service.replied?). to eq true
        end
      end

      context "when email is not found in SendGrid suppression lists" do
        before do
          allow_any_instance_of(EmailSuppressionManager).to receive(:unblock_email).and_return(false)
        end

        it "doesn't send a reply" do
          expect_any_instance_of(Helper::Client).not_to receive(:send_reply)

          unblock_email_service.process
        end
      end

      context "when a reply is already sent" do
        before do
          allow_any_instance_of(Helper::UnblockEmailService).to receive(:replied?).and_return(true)
        end

        it "unblocks email and doesn't send a reply again" do
          expect_any_instance_of(EmailSuppressionManager).to receive(:unblock_email)
          expect_any_instance_of(Helper::Client).not_to receive(:send_reply)

          unblock_email_service.process
        end
      end
    end

    context "when email is blocked by creator" do
      let(:reply) do
        <<~REPLY
        Hey there,

        It looks like a creator has blocked you from purchasing their products. Please reach out to them directly to resolve this.

        Feel free to write back to us if you have any questions.

        Thanks!
        REPLY
      end

      before do
        allow_any_instance_of(EmailSuppressionManager).to receive(:unblock_email).and_return(false)
        BlockedCustomerObject.block_email!(email:, seller_id: create(:user).id)
      end

      context "when auto_reply_for_blocked_emails_in_helper feature is active" do
        before do
          Feature.activate(:auto_reply_for_blocked_emails_in_helper)
        end

        it "drafts the reply" do
          expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply), draft: true, response_to: email_id)

          unblock_email_service.process
        end
      end

      context "when auto_reply_for_blocked_emails_in_helper feature is not active" do
        before do
          Feature.deactivate(:auto_reply_for_blocked_emails_in_helper)
        end

        it "drafts a reply" do
          expect_any_instance_of(Helper::Client).to receive(:send_reply).with(conversation_id:, message: simple_format(reply), draft: true, response_to: email_id)

          unblock_email_service.process
        end
      end
    end
  end
end
