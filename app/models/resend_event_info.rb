# frozen_string_literal: true

class ResendEventInfo < EmailEventInfo
  attr_reader \
    :charge_id, :click_url, :email, :event_json, :installment_id,
    :mailer_class, :mailer_method, :mailer_args, :purchase_id, :workflow_ids, :type, :created_at

  # Sample payload
  # event_json = HashWithIndifferentAccess.new({
  #   "created_at": "2025-01-02T00:14:12.391Z",
  #   "data": {
  #     "created_at": "2025-01-02 00:14:11.140106+00",
  #     "email_id": "7409b6f1-56f1-4ba5-89f0-4364a08b246e",
  #     "from": "\"Razvan\" <noreply@staging.customers.gumroad.com>",
  #     "headers": [
  #       {
  #         "name": "X-Gum-Environment",
  #         "value": "v1:T4Atudv1nP58+gprjqKMJA==:fGNbbVO69Zrw7kSnULg2mw=="
  #       },
  #       {
  #         "name": "X-Gum-Mailer-Class",
  #         "value": "v1:4/KqqxSld7KZg35TizeOzg==:roev9VWcJg5De5uJ95tWbQ=="
  #       },
  #       {
  #         "name": "X-Gum-Mailer-Method",
  #         "value": "v1:27cEW99BqALnRhqJcqq4yg==:JnxrbX321BGYsKX8wAANFg=="
  #       },
  #       {
  #         "name": "X-Gum-Mailer-Args",
  #         "value": "v1:pqH9QUfHKV1VUURMgRzN6Q==:sDje7QqsyOWz9kH542EpEA=="
  #       },
  #       {
  #         "name": "X-Gum-Category",
  #         "value": "v1:O85BjjvFY9LSq0ECcPnh0g==:7qblpHdeZxUdjTDM0XoSW/I3UIeKt8Cv41jTWssgmAcABmCfjtukxHl7RimCCSnD"
  #       },
  #       {
  #         "name": "X-Gum-Charge-ID",
  #         "value": "v1:sI/i9tSEYbiXU3kcb7iF+Q==:5f1Ls/SJFFUF+6L6VZc7CQ=="
  #       },
  #       {
  #         "name": "X-Gum-Email-Provider",
  #         "value": "resend"
  #       },
  #       {
  #         "name": "Reply-To",
  #         "value": "gumroad@marescu.net"
  #       }
  #     ],
  #     "subject": "You bought Prod with license!",
  #     "to": [
  #       "gumroad+cust4@marescu.net"
  #     ]
  #   },
  #   "type": "email.delivered"
  # })
  def self.from_event_json(event_json)
    new(event_json)
  end

  def initialize(event_json)
    @event_json = event_json
    @email = event_json["data"]["to"].first
    @click_url = event_json["data"].dig("click", "link")
    @mailer_class = parse_header_value(:mailer_class)
    @mailer_method = parse_header_value(:mailer_method)
    @mailer_args = parse_header_value(:mailer_args)
    @purchase_id = parse_header_value(:purchase_id)
    @charge_id = parse_header_value(:charge_id)
    @workflow_ids = parse_workflow_ids
    @type = TRACKED_EVENTS[MailerInfo::EMAIL_PROVIDER_RESEND].invert[event_json["type"]]
    @created_at = Time.zone.parse(event_json["data"]["created_at"])
    @installment_id = parse_header_value(:post_id)
  end

  def invalid?
    type.blank? || mailer_class.blank? || mailer_method.blank?
  end

  def mailer_class_and_method
    "#{mailer_class}.#{mailer_method}"
  end

  def email_provider
    MailerInfo::EMAIL_PROVIDER_RESEND
  end

  private
    def parse_header_value(header_name)
      MailerInfo.parse_resend_webhook_header(event_json["data"]["headers"], header_name)
    end

    def parse_workflow_ids
      value = parse_header_value(:workflow_ids)
      return [] if value.blank?

      JSON.parse(value.to_s)
    end
end
