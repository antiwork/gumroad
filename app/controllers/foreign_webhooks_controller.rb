# frozen_string_literal: true

class ForeignWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :validate_sns_webhook, only: [:mediaconvert]

  before_action only: [:stripe] do
    endpoint_secret = GlobalConfig.dig(:stripe, :endpoint_secret)
    validate_stripe_webhook(endpoint_secret)
  end

  before_action only: [:stripe_connect] do
    endpoint_secret = GlobalConfig.dig(:stripe_connect, :endpoint_secret)
    validate_stripe_webhook(endpoint_secret)
  end

  before_action only: [:resend] do
    endpoint_secret = GlobalConfig.get("RESEND_WEBHOOK_SECRET")
    validate_resend_webhook(endpoint_secret)
  end

  def stripe
    if @stripe_event["id"]
      HandleStripeEventWorker.perform_async(@stripe_event.as_json)
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def stripe_connect
    if @stripe_event["id"].present? && (@stripe_event["account"].present? || @stripe_event["user_id"].present?)
      HandleStripeEventWorker.perform_async(@stripe_event.as_json)
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def paypal
    payload = params.to_unsafe_hash.except(:controller, :action, :format, :foreign_webhook).to_hash

    if payload["event_type"].present?
      verifier = PaypalWebhookVerifier.new(
        headers: request.headers.env,
        raw_body: request.raw_post,
        fallback_payload: payload
      )
      if verifier.valid? == false
        Rails.logger.warn("Rejected PayPal webhook because signature validation failed")
        return render json: { success: false }, status: :bad_request
      end
    end

    PaypalEventHandler.new(payload).schedule_paypal_event_processing

    render json: { success: true }
  end

  def sendgrid
    HandleSendgridEventJob.perform_async(params.to_unsafe_hash.to_hash)
    LogSendgridEventWorker.perform_async(params.to_unsafe_hash.to_hash)

    render json: { success: true }
  end

  def resend
    HandleResendEventJob.perform_async(params.to_unsafe_hash.to_hash)
    LogResendEventJob.perform_async(params.to_unsafe_hash.to_hash)

    render json: { success: true }
  end

  def sns
    # The SNS post has json body but the content-type is set to plain text.
    notification_message = request.body.read

    Rails.logger.info("Incoming SNS (Transcoder): #{notification_message}")
    # TODO(amir): remove this once elastic transcoder support gets back to us about why it's included and causing the json to be invalid.
    Rails.logger.info("Incoming SNS from Elastic Transcoder contains the invalid characters? #{notification_message.include?('#012')}")

    notification_message.gsub!("#012", "")
    HandleSnsTranscoderEventWorker.perform_in(5.seconds, JSON.parse(notification_message))

    head :ok
  end

  def mediaconvert
    notification = JSON.parse(request.raw_post)
    Rails.logger.info "Incoming SNS (MediaConvert): #{notification}"

    HandleSnsMediaconvertEventWorker.perform_in(5.seconds, notification)
    head :ok
  end

  def sns_aws_config
    notification = request.body.read
    Rails.logger.info("Incoming SNS (AWS Config): #{notification}")
    HandleSnsAwsConfigEventWorker.perform_async(JSON.parse(notification))
    head :ok
  end

  private
    def validate_sns_webhook
      return if Aws::SNS::MessageVerifier.new.authentic?(request.raw_post)

      render json: { success: false }, status: :bad_request
    end

    def validate_stripe_webhook(endpoint_secret)
      payload = request.raw_post
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

      begin
        @stripe_event = Stripe::Webhook.construct_event(
          payload, sig_header, endpoint_secret
        )
      rescue JSON::ParserError
        # Invalid payload
        render json: { success: false }, status: :bad_request
      rescue Stripe::SignatureVerificationError
        # Invalid signature
        render json: { success: false }, status: :bad_request
      end
    end

    def validate_resend_webhook(secret)
      payload = request.body.read
      signature_header = request.headers["svix-signature"]
      timestamp = request.headers["svix-timestamp"]
      message_id = request.headers["svix-id"]

      raise "Missing signature" if signature_header.blank?
      raise "Missing timestamp" if timestamp.blank?
      raise "Missing message ID" if message_id.blank?

      # Verify timestamp is within 5 minutes
      timestamp_dt = Time.at(timestamp.to_i)
      if (Time.current.utc - timestamp_dt).abs > 5.minutes
        raise "Timestamp too old"
      end

      # Parse signature header (format: "v1,<signature>")
      _, signature = signature_header.split(",", 2)
      raise "Invalid signature format" if signature.blank?

      # Get the base64 portion after whsec_ and decode it
      secret_bytes = Base64.decode64(secret.split("_", 2).last)

      # Calculate HMAC using SHA256
      signed_payload = "#{message_id}.#{timestamp}.#{payload}"
      expected = Base64.strict_encode64(
        OpenSSL::HMAC.digest("SHA256", secret_bytes, signed_payload)
      )

      # Compare signatures using secure comparison
      raise "Invalid signature" unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    rescue => e
      Bugsnag.notify("Error verifying Resend webhook: #{e.message}")
      render json: { success: false }, status: :bad_request
    end
end
