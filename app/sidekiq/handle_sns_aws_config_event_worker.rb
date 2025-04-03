# frozen_string_literal: true

class HandleSnsAwsConfigEventWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :mongo

  MESSAGE_TYPES_TO_IGNORE = %w[
    ConfigurationSnapshotDeliveryStarted
    ConfigurationSnapshotDeliveryCompleted
    ConfigurationHistoryDeliveryCompleted
  ].freeze
  private_constant :MESSAGE_TYPES_TO_IGNORE

  def build_default_attachment(params)
    {
      color: "danger",
      text: "```\n#{JSON.pretty_generate(params)}\n```",
      mrkdwn_in: ["text"]
    }
  end

  def build_message(message)
    configuration_item = message["configurationItem"]
    configuration_item_diff = message["configurationItemDiff"]
    return if configuration_item.nil? || configuration_item_diff.nil?

    region = configuration_item["awsRegion"] || AWS_DEFAULT_REGION
    timestamp = configuration_item["configurationItemCaptureTime"]
    resource_type = configuration_item["resourceType"]
    resource_id = configuration_item["resourceId"]
    resource_name = configuration_item["tags"].try(:[], "Name")
    related_cloudtrail_events = configuration_item["relatedEvents"]
    return if timestamp.nil? || resource_type.nil? || resource_id.nil? || related_cloudtrail_events.nil?

    config_url = "https://console.aws.amazon.com/config/home?region=#{region}#/timeline/#{resource_type}/#{resource_id}?time=#{timestamp}"

    "#{resource_id} • #{resource_name} • <#{config_url}|AWS Config>"
  end

  def perform(params)
    if params["Type"] == "Notification"
      message_content = JSON.parse(params["Message"])
      message_type = message_content["messageType"]

      return if MESSAGE_TYPES_TO_IGNORE.include?(message_type)

      message = build_message(message_content)
    end

    if message
      SlackMessageWorker.perform_async("internals_log", "AWS Config", message, "gray")
    else
      attachment = build_default_attachment(params)
      SlackMessageWorker.perform_async("internals_log", "AWS Config", "", "red", attachments: [attachment])
    end
  end
end
