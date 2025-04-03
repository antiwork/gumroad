# frozen_string_literal: true

require "openssl"

class MailerInfo::HeaderBuilder
  attr_reader :mailer_class, :email_provider
  attr_reader :mailer_args
  attr_reader :mailer_method
  def self.perform(mailer_class:, mailer_method:, mailer_args:, email_provider:)
    new(mailer_class:, mailer_method:, mailer_args:, email_provider:).perform
  end

  def initialize(mailer_class:, mailer_method:, mailer_args:, email_provider:)
    @mailer_class = mailer_class
    @mailer_method = mailer_method
    @mailer_args = mailer_args
    @email_provider = email_provider
  end

  def perform
    if email_provider == MailerInfo::EMAIL_PROVIDER_RESEND
      build_for_resend
    else
      build_for_sendgrid
    end
  end

  def build_for_sendgrid
    purchase_id, charge_id = determine_receipt_record_ids
    {
      MailerInfo.header_name(:email_provider) => MailerInfo::EMAIL_PROVIDER_SENDGRID,
      # This header field name must match the one used by SendGrid
      # https://www.twilio.com/docs/sendgrid/for-developers/sending-email/building-an-x-smtpapi-header
      MailerInfo::SENDGRID_X_SMTPAPI_HEADER => {
        environment: Rails.env,
        category: [mailer_class, "#{mailer_class}.#{mailer_method}"],
        unique_args: {
          MailerInfo::FIELD_MAILER_CLASS => mailer_class,
          MailerInfo::FIELD_MAILER_METHOD => mailer_method,
          MailerInfo::FIELD_MAILER_ARGS => truncated_mailer_args.inspect,
          MailerInfo::FIELD_PURCHASE_ID => purchase_id,
          MailerInfo::FIELD_CHARGE_ID => charge_id,
        }.compact
      }.to_json
    }.compact
  end

  def build_for_resend
    purchase_id, charge_id = determine_receipt_record_ids
    post_purchase_id, follower_id, affiliate_id, post_id = determine_installment_record_ids
    workflow_ids = determine_cart_abandoned_workflow_ids
    headers = {
      MailerInfo::FIELD_ENVIRONMENT => Rails.env,
      MailerInfo::FIELD_MAILER_CLASS => mailer_class,
      MailerInfo::FIELD_MAILER_METHOD => mailer_method,
      MailerInfo::FIELD_MAILER_ARGS => truncated_mailer_args,
      MailerInfo::FIELD_CATEGORY => [mailer_class, mailer_method.presence && "#{mailer_class}.#{mailer_method}"].compact.to_json,
      MailerInfo::FIELD_PURCHASE_ID => purchase_id || post_purchase_id,
      MailerInfo::FIELD_CHARGE_ID => charge_id,
      MailerInfo::FIELD_WORKFLOW_IDS => workflow_ids,
      MailerInfo::FIELD_FOLLOWER_ID => follower_id,
      MailerInfo::FIELD_AFFILIATE_ID => affiliate_id,
      MailerInfo::FIELD_POST_ID => post_id
    }.compact.transform_keys { MailerInfo.header_name(_1) }
      .transform_values { MailerInfo.encrypt(_1) }
    headers[MailerInfo.header_name(:email_provider)] = MailerInfo::EMAIL_PROVIDER_RESEND
    headers
  end

  def determine_installment_record_ids
    purchase_id, follower_id, affiliate_id, post_id = nil, nil, nil, nil
    if EmailEventInfo::TRACKED_INSTALLMENT_MAILER_METHODS.include?(mailer_method)
      post_id = mailer_args[1]
    end

    if mailer_method == EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD
      purchase_id = mailer_args[0]
    elsif mailer_method == EmailEventInfo::FOLLOWER_INSTALLMENT_MAILER_METHOD
      follower_id = mailer_args[0]
    elsif mailer_method == EmailEventInfo::DIRECT_AFFILIATE_INSTALLMENT_MAILER_METHOD
      affiliate_id = mailer_args[0]
    end

    [purchase_id, follower_id, affiliate_id, post_id]
  end

  def determine_receipt_record_ids
    return [nil, nil] unless receipt_email?
    purchase_id, charge_id = mailer_args.slice(0, 2)
    if mailer_method == SendgridEventInfo::RECEIPT_MAILER_METHOD
      # Ensures the correct EmailInfo record will be used, and no duplicates are created
      # Use case:
      # 1. Sending the first receipt uses charge_id, and EmailInfo + EmailInfoCharge records are created
      # 2. Resending the receipt uses purchase_id.
      # We want the 2nd receipt to update the existing EmailInfo record (with a charge), not create a new one
      chargeable = Charge::Chargeable.find_by_purchase_or_charge!(
        purchase: Purchase.find_by(id: purchase_id),
        charge: Charge.find_by(id: charge_id)
      )
      chargeable.is_a?(Charge) ? [nil, chargeable.id] : [purchase_id, nil]
    elsif mailer_method == SendgridEventInfo::PREORDER_RECEIPT_MAILER_METHOD
      [Preorder.find(purchase_id).authorization_purchase.id, nil]
    else
      [nil, nil]
    end
  end

  def receipt_email?
    return false if mailer_class != CustomerMailer.to_s
    mailer_method.in? SendgridEventInfo::PREORDER_RECEIPT_MAILER_METHOD
  end

  def determine_cart_abandoned_workflow_ids
    return nil unless abandoned_cart_email?
    raise ArgumentError.new("Abandoned cart email event has unexpected mailer_args size: #{mailer_args.inspect}") if mailer_args.size != 2

    mailer_args.second.keys.to_json
  end

  def abandoned_cart_email?
    mailer_class == CustomerMailer.to_s && mailer_method == EmailEventInfo::ABANDONED_CART_MAILER_METHOD
  end

  # Minimize the chances for the unique arguments to surpass 10k bytes
  # https://docs.sendgrid.com/for-developers/sending-email/unique-arguments
  def truncated_mailer_args
    mailer_args.map { |argument| argument.is_a?(String) ? argument[0..19] : argument }
  end
end
