# frozen_string_literal: true

require "test_helper"

class MailerInfoDeliveryMethodTest < ActiveSupport::TestCase
  self.described_class = MailerInfo::DeliveryMethod



  context_ MailerInfo::DeliveryMethod do
  context_ ".options" do
      let(:email_provider) { MailerInfo::EMAIL_PROVIDER_SENDGRID }

  context_ "with invalid domain" do
  test "raises ArgumentError" do
          expect { described_class.options(domain: :invalid, email_provider:) }
            .to raise_error(ArgumentError, "Invalid domain: invalid")
        end
      end

  context_ "with seller for non-customers domain" do
        let(:seller) { create(:user) }

  test "raises ArgumentError" do
          expect { described_class.options(domain: :gumroad, email_provider:, seller:) }
            .to raise_error(ArgumentError, "Seller is only allowed for customers domain")
        end
      end

  context_ "with SendGrid" do
  test "returns basic options" do
          expect(described_class.options(domain: :gumroad, email_provider:)).to eq({
                                                                                     address: SENDGRID_SMTP_ADDRESS,
                                                                                     domain: DEFAULT_EMAIL_DOMAIN,
                                                                                     user_name: "apikey",
                                                                                     password: GlobalConfig.get("SENDGRID_GUMROAD_TRANSACTIONS_API_KEY")
                                                                                   })
        end
      end

  context_ "with Resend" do
        let(:email_provider) { MailerInfo::EMAIL_PROVIDER_RESEND }

  test "returns basic options" do
          expect(described_class.options(domain: :gumroad, email_provider:)).to eq({
                                                                                     address: RESEND_SMTP_ADDRESS,
                                                                                     domain: DEFAULT_EMAIL_DOMAIN,
                                                                                     user_name: "resend",
                                                                                     password: GlobalConfig.get("RESEND_DEFAULT_API_KEY")
                                                                                   })
        end
      end

  context_ "with seller" do
        let(:seller) { create(:user) }

        before do
          allow(seller).to receive(:mailer_level).and_return(:level_1)
        end

  test "returns seller-specific options" do
          expect(described_class.options(domain: :customers, email_provider:, seller:)).to eq({
                                                                                                address: SENDGRID_SMTP_ADDRESS,
                                                                                                domain: CUSTOMERS_MAIL_DOMAIN,
                                                                                                user_name: "apikey",
                                                                                                password: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_API_KEY")
                                                                                              })
        end
      end
    end
  end
end
