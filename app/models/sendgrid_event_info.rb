# frozen_string_literal: true

class SendgridEventInfo < EmailEventInfo
  attr_reader \
    :charge_id, :click_url, :email, :event_json, :installment_id, :mailer_args, :mailer_class_and_method,
    :mailer_class, :mailer_method, :purchase_id, :type, :created_at

  def initialize(event_json)
    @event_json = event_json
    @email = event_json["email"]
    @click_url = event_json["url"]
    @installment_id = event_json["installment_id"]
    @type = TRACKED_EVENTS[MailerInfo::EMAIL_PROVIDER_SENDGRID].invert[event_json["event"]]
    @created_at = Time.zone.at(event_json["timestamp"]) if event_json.key?("timestamp")
    if event_json["type"].present? && event_json["identifier"].present?
      initialize_from_type_and_identifier_unique_args(event_json)
    else
      initialize_from_record_level_unique_args(event_json)
    end
  end

  def invalid?
    # The event must have a type (otherwise it's not tracked), and appropriate metadata
    type.blank? || mailer_class_and_method.blank? || mailer_args.blank?
  end

  # Used by HandleEmailEventInfo::ForAbandonedCartEmail
  def workflow_ids
    # mailer_args is a string that looks like this: "[3783, {\"5296\"=>[153758, 163413], \"5644\"=>[163413]}]"
    parsed_mailer_args = JSON.parse(mailer_args.gsub("=>", ":")) rescue []

    if parsed_mailer_args.size != 2
      Bugsnag.notify("Abandoned cart email event has unexpected mailer_args size", mailer_args:)
      return []
    end

    _cart_id, workflows_ids_with_product_ids = parsed_mailer_args
    workflows_ids_with_product_ids.keys
  end

  def email_provider
    MailerInfo::EMAIL_PROVIDER_SENDGRID
  end

  private
    # Old data structure that is used by post emails (via PostSendgridApi), and it was used by receipt emails until
    # Mar 2024. Should be kept around unless we no longer want to parse events for emails sent using the old data
    # structure.
    # Sample SendgGrid header:
    # {
    #   "environment": "test",
    #   "category": ["CustomerMailer" , "CustomerMailer.receipt"],
    #   "unique_args": {
    #     "identifier": "[1]",
    #     "type": "CustomerMailer.receipt"
    #   }
    # }
    def initialize_from_type_and_identifier_unique_args(event_json)
      @mailer_class_and_method = event_json["type"]
      @mailer_class, @mailer_method = @mailer_class_and_method.split(".", 2)
      @mailer_args = event_json["identifier"]
      @purchase_id = find_purchase_id_from_mailer_args
    end

    def find_purchase_id_from_mailer_args
      id = mailer_args.gsub(/\[|\]/, "").split(",").first.to_i
      if mailer_class_and_method == "#{CUSTOMER_MAILER}.#{PREORDER_RECEIPT_MAILER_METHOD}"
        Preorder.find(id).authorization_purchase.id
      else
        id
      end
    end

    # Sample SendGrid header:
    # {
    #   "environment": "test",
    #   "category": ["CustomerMailer" , "CustomerMailer.receipt"],
    #   "unique_args": {
    #     "purchase_id": 1,
    #     "mailer_class": "CustomerMailer",
    #     "mailer_method":"receipt"
    #   }
    # }
    def initialize_from_record_level_unique_args(event_json)
      @mailer_class_and_method = "#{event_json["mailer_class"]}.#{event_json["mailer_method"]}"
      @mailer_class = event_json["mailer_class"]
      @mailer_method = event_json["mailer_method"]
      @mailer_args = event_json["mailer_args"]
      @purchase_id = event_json["purchase_id"]
      @charge_id = event_json["charge_id"]
    end
end
