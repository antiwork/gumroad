# frozen_string_literal: true

require "test_helper"

class EmailDeliveryObserverHandleCustomerEmailInfoTest < ActiveSupport::TestCase
  self.described_class = EmailDeliveryObserver::HandleCustomerEmailInfo



  context_ EmailDeliveryObserver::HandleCustomerEmailInfo do
    let(:purchase) { create(:purchase) }

  context_ ".perform" do
      shared_examples "CustomerMailer.receipt" do
  context_ "for a Purchase" do
  context_ "when CustomerEmailInfo record doesn't exist" do
  test "creates a record and marks as sent" do
              expect do
                CustomerMailer.receipt(purchase.id, nil, for_email: true).deliver_now
              end.to change { CustomerEmailInfo.count }.by(1)

              email_info = CustomerEmailInfo.last
              expect(email_info.purchase).to eq(purchase)
              expect(email_info.email_name).to eq("receipt")
              expect(email_info.sent_at).to be_present
            end
          end

  context_ "when CustomerEmailInfo record exists" do
            let!(:customer_email_info) { create(:customer_email_info, purchase: purchase, email_name: "receipt") }

  test "finds the record and marks as sent" do
              expect do
                CustomerMailer.receipt(purchase.id, nil, for_email: true).deliver_now
              end.not_to change { CustomerEmailInfo.count }

              expect(customer_email_info.reload.sent_at).to be_present
            end
          end
        end

  context_ "for a Charge" do
          let(:charge) { create(:charge, purchases: [purchase]) }
          let(:order) { charge.order }

          before do
            order.purchases << purchase
          end

  context_ "when CustomerEmailInfo record doesn't exist" do
  test "creates a record and marks as sent" do
              expect do
                CustomerMailer.receipt(nil, charge.id, for_email: true).deliver_now
              end.to change { CustomerEmailInfo.count }.by(1)

              email_info = CustomerEmailInfo.last
              expect(email_info.purchase).to be(nil)
              expect(email_info.email_info_charge.charge_id).to eq(charge.id)
              expect(email_info.email_name).to eq("receipt")
              expect(email_info.sent_at).to be_present
            end
          end

  context_ "when CustomerEmailInfo record exists" do
            let!(:customer_email_info) do
              email_info = CustomerEmailInfo.new(email_name: "receipt")
              email_info.build_email_info_charge(charge_id: charge.id)
              email_info.save!
              email_info
            end

  test "finds the record and marks as sent" do
              expect do
                CustomerMailer.receipt(nil, charge.id, for_email: true).deliver_now
              end.not_to change { CustomerEmailInfo.count }

              expect(customer_email_info.reload.sent_at).to be_present
            end

  context_ "when using purchase_id as argument" do
  test "finds the record and marks as sent" do
                expect do
                  CustomerMailer.receipt(purchase.id, nil, for_email: true).deliver_now
                end.not_to change { CustomerEmailInfo.count }

                expect(customer_email_info.reload.sent_at).to be_present
              end
            end
          end
        end
      end

      shared_examples "CustomerMailer.preorder" do
        let(:preorder) do
          create(:preorder, preorder_link: create(:preorder_link, link: purchase.link))
        end

        before do
          purchase.update!(preorder:)
        end

  context_ "when CustomerEmailInfo record doesn't exist" do
  test "marks creates a record and marks as sent" do
            expect do
              CustomerMailer.preorder_receipt(preorder.id).deliver_now
            end.to change { CustomerEmailInfo.count }.by(1)

            email_info = CustomerEmailInfo.last
            expect(email_info.purchase).to eq(purchase)
            expect(email_info.email_name).to eq("preorder_receipt")
            expect(email_info.sent_at).to be_present
          end
        end

  context_ "when CustomerEmailInfo record exists" do
          let!(:customer_email_info) { create(:customer_email_info, purchase: purchase, email_name: "preorder_receipt") }

  test "finds the record and marks as sent" do
            expect do
              CustomerMailer.preorder_receipt(preorder.id).deliver_now
            end.not_to change { CustomerEmailInfo.count }

            expect(customer_email_info.reload.sent_at).to be_present
          end
        end
      end

      shared_examples "mailer method is not supported" do
  test "doesn't raise and it doesn't create a record" do
          expect do
            expect do
              CustomerMailer.grouped_receipt([purchase.id]).deliver_now
            end.not_to raise_error
          end.not_to change { CustomerEmailInfo.count }
        end
      end

      shared_examples "mailer class is not supported" do
  test "doesn't raise and it doesn't create a record" do
          expect do
            expect do
              ContactingCreatorMailer.chargeback_notice(create(:dispute, purchase:).id).deliver_now
            end.not_to raise_error
          end.not_to change { CustomerEmailInfo.count }
        end
      end

  context_ "with SendGrid" do
        it_behaves_like "CustomerMailer.receipt"
        it_behaves_like "CustomerMailer.preorder"
        it_behaves_like "mailer method is not supported"
        it_behaves_like "mailer class is not supported"

  context_ "when the SendGrid header is invalid" do
          let(:message) { instance_double(Mail::Message) }
          let(:header) { instance_double(Mail::Header) }
          let(:smtpapi_header_value) { "invalid" }
          let(:smtpapi_header_field) { Mail::Field.new(MailerInfo::SENDGRID_X_SMTPAPI_HEADER, smtpapi_header_value) }
          let(:email_provider_header_field) { Mail::Field.new(MailerInfo.header_name(:email_provider), MailerInfo::EMAIL_PROVIDER_SENDGRID) }

          before do
            allow(message).to receive(:header).and_return(
              {
                MailerInfo.header_name(:email_provider) => email_provider_header_field,
                MailerInfo::SENDGRID_X_SMTPAPI_HEADER => smtpapi_header_field,
              }
            )
          end

  test "notifies error tracker" do
            expect(ErrorNotifier).to receive(:notify) do |error|
              expect(error).to be_a(EmailDeliveryObserver::HandleCustomerEmailInfo::InvalidHeaderError)
              expect(error.message.to_s).to eq("Failed to parse sendgrid header: unexpected character: 'invalid' at line 1 column 1")
              expect(JSON.parse(error.sentry_context[:debug]).keys).to include(MailerInfo::SENDGRID_X_SMTPAPI_HEADER)
            end

            expect do
              expect do
                EmailDeliveryObserver::HandleCustomerEmailInfo.perform(message)
              end.not_to raise_error
            end.not_to change { CustomerEmailInfo.count }
          end
        end
      end

  context_ "with Resend" do
        before do
          Feature.activate(:use_resend_for_application_mailer)
        end

        it_behaves_like "CustomerMailer.receipt"
        it_behaves_like "CustomerMailer.preorder"
        it_behaves_like "mailer method is not supported"
        it_behaves_like "mailer class is not supported"

  context_ "when the Resend header is invalid" do
          let(:message) { instance_double(Mail::Message) }
          let(:header) { instance_double(Mail::Header) }
          let(:header_value) { "invalid" }
          let(:header_field) { Mail::Field.new(MailerInfo.header_name(:mailer_class), header_value) }
          let(:email_provider_header_field) { Mail::Field.new(MailerInfo.header_name(:email_provider), MailerInfo::EMAIL_PROVIDER_RESEND) }

          before do
            allow(message).to receive(:header).and_return(
              {
                MailerInfo.header_name(:email_provider) => email_provider_header_field,
                MailerInfo.header_name(:mailer_class) => header_field,
              }
            )
          end

  test "notifies error tracker" do
            expect(ErrorNotifier).to receive(:notify) do |error|
              expect(error).to be_a(EmailDeliveryObserver::HandleCustomerEmailInfo::InvalidHeaderError)
              expect(error.message.to_s).to eq("Failed to parse resend header: undefined method 'value' for nil")
              expect(JSON.parse(error.sentry_context[:debug]).keys).to include(MailerInfo.header_name(:mailer_class))
            end

            expect do
              expect do
                EmailDeliveryObserver::HandleCustomerEmailInfo.perform(message)
              end.not_to raise_error
            end.not_to change { CustomerEmailInfo.count }
          end
        end
      end
    end
  end
end
