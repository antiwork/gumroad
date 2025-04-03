# frozen_string_literal: true

module EmailDeliveryObserver::HandleCustomerEmailInfo
  class InvalidHeaderError < StandardError
    attr_reader :metadata

    def initialize(message, metadata)
      super(message)
      @metadata = metadata
    end

    def bugsnag_meta_data
      { debug: metadata }
    end
  end

  extend self

  def perform(message)
    message_info = build_message_info(message)
    return if message_info.ignore?

    email_info = find_or_initialize_customer_email_info(**message_info.attributes)
    email_info.mark_sent!
  rescue InvalidHeaderError => e
    Bugsnag.notify(e)
  end

  private
    def build_message_info(message)
      mailer_method_name, purchase_id, charge_id = parse_message_headers(message)

      OpenStruct.new(
        ignore?: purchase_id.nil? && charge_id.nil?,
        attributes: {
          email_name: mailer_method_name,
          purchase_id:,
          charge_id:,
        },
      )
    end

    def find_or_initialize_customer_email_info(email_name:, purchase_id:, charge_id:)
      if charge_id.present?
        CustomerEmailInfo.find_or_initialize_for_charge(charge_id:, email_name:)
      else
        CustomerEmailInfo.find_or_initialize_for_purchase(purchase_id:, email_name:)
      end
    end

    def parse_message_headers(message)
      email_provider = message.header[MailerInfo.header_name(:email_provider)].value

      case email_provider
      when MailerInfo::EMAIL_PROVIDER_SENDGRID
        parse_sendgrid_headers(message)
      when MailerInfo::EMAIL_PROVIDER_RESEND
        parse_resend_headers(message)
      else
        raise "Unknown email provider: #{email_provider}"
      end
    rescue => e
      raise InvalidHeaderError.new(
        "Failed to parse #{email_provider} header: #{e.message}",
        message.header.to_json
      )
    end

    # Sample SendGrid header:
    # For purchase:
    # {
    #   "environment": "test",
    #   "category": ["CustomerMailer" , "CustomerMailer.receipt"],
    #   "unique_args": {
    #     "purchase_id": 1,
    #     "mailer_class": "CustomerMailer",
    #     "mailer_method":"receipt"
    #   }
    # }
    # For charge:
    # {
    #   "environment": "test",
    #   "category": ["CustomerMailer" , "CustomerMailer.receipt"],
    #   "unique_args": {
    #     "charge_id": 1,
    #     "mailer_class": "CustomerMailer",
    #     "mailer_method":"receipt"
    #   }
    # }
    def parse_sendgrid_headers(message)
      sendgrid_header = message.header[MailerInfo::SENDGRID_X_SMTPAPI_HEADER].value
      data = JSON.parse(sendgrid_header)["unique_args"]
      [data["mailer_method"], data["purchase_id"], data["charge_id"]]
    end

    # Sample Resend header (unencrypted):
    # {
    #   "X-GUM-Email-Provider"=>"resend",
    #   "X-GUM-Environment"=>"development",
    #   "X-GUM-Category"=>"[\"CustomerMailer\",\"CustomerMailer.receipt\"]",
    #   "X-GUM-Mailer-Class"=>"CustomerMailer",
    #   "X-GUM-Mailer-Method"=>"receipt",
    #   "X-GUM-Mailer-Args"=>"\"[1]\"",
    #   "X-GUM-Purchase-Id"=>1,
    #   "X-GUM-Workflow-Ids"=>"[1,2,3]"
    # }
    def parse_resend_headers(message)
      [
        message.header[MailerInfo.header_name(:mailer_method)].value,
        message.header[MailerInfo.header_name(:purchase_id)]&.value,
        message.header[MailerInfo.header_name(:charge_id)]&.value,
      ].map { MailerInfo.decrypt(_1) }
    end
end
