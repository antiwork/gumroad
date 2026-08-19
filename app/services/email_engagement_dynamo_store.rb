# frozen_string_literal: true

# Dual-write adapter for the DynamoDB table replacing the CreatorEmailOpenEvent /
# CreatorEmailClickEvent / CreatorEmailClickSummary Mongo collections.
#
# Partition key `pk` (S, the stringified installment id), sort key `sk` (S), one of:
#   SUMMARY                    — open_count / click_count counters for the installment
#   OPEN#<recipient>           — one item per recipient who opened
#   CLICK#<recipient>#<url>    — one item per recipient + url first click
#   URL#<url>                  — unique-click total for one url
# <recipient> and <url> are SHA256 hex digests (raw values are attributes on the
# items). CLICK keys are recipient-first so "has this recipient clicked anything?"
# is a begins_with query; per-url totals are separate items rather than a map on
# SUMMARY so link-heavy posts can't grow SUMMARY toward the 400KB item cap.
class EmailEngagementDynamoStore
  TABLE_BASE_NAME = "email_engagement"
  SUMMARY_SORT_KEY = "SUMMARY"
  DUAL_WRITE_FEATURE = :email_engagement_dynamodb_dual_write

  class << self
    attr_writer :client

    def record_open(installment_id:, mailer_method:, mailer_args:)
      with_dual_write_guard do
        upsert_open_item(installment_id: installment_id.to_i, mailer_method:, mailer_args:)
      end
    end

    def record_click(installment_id:, mailer_method:, mailer_args:, click_url:)
      with_dual_write_guard do
        installment_id = installment_id.to_i
        recipient = recipient_digest(mailer_method:, mailer_args:)
        first_click_for_recipient = !recipient_clicked_any_url?(installment_id:, recipient:)

        # A repeat click of the same url by the same recipient counts nothing,
        # matching the Mongo path's early return.
        next unless put_click_item(installment_id:, mailer_method:, mailer_args:, click_url:, recipient:)

        increment_url_click_count(installment_id:, click_url:)
        increment_summary(installment_id:, attribute: "click_count") if first_click_for_recipient
        # A click implies an open; compensates for blocked tracking pixels.
        ensure_open_item(installment_id:, mailer_method:, mailer_args:)
      end
    end

    def client
      # An explicit endpoint is always passed because the global Aws.config
      # endpoint override points at S3/MinIO in development and test.
      @client ||= Aws::DynamoDB::Client.new(endpoint: ENV["DYNAMODB_ENDPOINT"].presence)
    end

    def table_name
      "#{ENV["DYNAMODB_TABLE_PREFIX"]}#{TABLE_BASE_NAME}"
    end

    # Staging and production tables are Terraform-owned (antiwork/infrastructure#998)
    # and deletion-protected; this bootstrap is for dev, test, and branch apps.
    def create_table!
      client.create_table(
        table_name:,
        attribute_definitions: [
          { attribute_name: "pk", attribute_type: "S" },
          { attribute_name: "sk", attribute_type: "S" },
        ],
        key_schema: [
          { attribute_name: "pk", key_type: "HASH" },
          { attribute_name: "sk", key_type: "RANGE" },
        ],
        billing_mode: "PAY_PER_REQUEST"
      )
    end

    # The backfill must derive identical keys from the Mongo documents, so key
    # derivation is public and must not change while Mongo remains around.
    def partition_key(installment_id)
      installment_id.to_i.to_s
    end

    def recipient_digest(mailer_method:, mailer_args:)
      Digest::SHA256.hexdigest("#{mailer_method}\n#{mailer_args}")
    end

    def url_digest(click_url)
      Digest::SHA256.hexdigest(click_url)
    end

    def open_sort_key(mailer_method:, mailer_args:)
      "OPEN##{recipient_digest(mailer_method:, mailer_args:)}"
    end

    def click_sort_key(mailer_method:, mailer_args:, click_url:)
      "CLICK##{recipient_digest(mailer_method:, mailer_args:)}##{url_digest(click_url)}"
    end

    def url_sort_key(click_url)
      "URL##{url_digest(click_url)}"
    end

    private
      def with_dual_write_guard
        return unless Feature.active?(DUAL_WRITE_FEATURE)
        yield
      rescue => e
        # Mongo remains the source of truth during dual writes; a DynamoDB
        # failure must not fail email event processing.
        ErrorNotifier.notify(e)
      end

      def upsert_open_item(installment_id:, mailer_method:, mailer_args:)
        now = timestamp
        previous = client.update_item(
          table_name:,
          key: item_key(installment_id, open_sort_key(mailer_method:, mailer_args:)),
          update_expression: "ADD open_count :one " \
                             "SET mailer_method = :mailer_method, mailer_args = :mailer_args, " \
                             "first_open_at = if_not_exists(first_open_at, :now), last_open_at = :now",
          expression_attribute_values: { ":one" => 1, ":mailer_method" => mailer_method, ":mailer_args" => mailer_args, ":now" => now },
          return_values: "ALL_OLD"
        )
        increment_summary(installment_id:, attribute: "open_count") if previous.attributes.blank?
      end

      # Creates the open item only if absent, without touching an existing item's
      # open_count, mirroring the Mongo compensating-open behavior on clicks.
      def ensure_open_item(installment_id:, mailer_method:, mailer_args:)
        now = timestamp
        client.put_item(
          table_name:,
          item: {
            "pk" => partition_key(installment_id),
            "sk" => open_sort_key(mailer_method:, mailer_args:),
            "mailer_method" => mailer_method,
            "mailer_args" => mailer_args,
            "open_count" => 1,
            "first_open_at" => now,
            "last_open_at" => now,
          },
          condition_expression: "attribute_not_exists(pk)"
        )
        increment_summary(installment_id:, attribute: "open_count")
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        nil
      end

      def put_click_item(installment_id:, mailer_method:, mailer_args:, click_url:, recipient:)
        client.put_item(
          table_name:,
          item: {
            "pk" => partition_key(installment_id),
            "sk" => "CLICK##{recipient}##{url_digest(click_url)}",
            "mailer_method" => mailer_method,
            "mailer_args" => mailer_args,
            "click_url" => click_url,
            "click_count" => 1,
            "first_click_at" => timestamp,
          },
          condition_expression: "attribute_not_exists(pk)"
        )
        true
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        false
      end

      def recipient_clicked_any_url?(installment_id:, recipient:)
        client.query(
          table_name:,
          key_condition_expression: "pk = :pk AND begins_with(sk, :sk_prefix)",
          expression_attribute_values: { ":pk" => partition_key(installment_id), ":sk_prefix" => "CLICK##{recipient}#" },
          select: "COUNT",
          limit: 1,
          consistent_read: true
        ).count.positive?
      end

      def increment_url_click_count(installment_id:, click_url:)
        client.update_item(
          table_name:,
          key: item_key(installment_id, url_sort_key(click_url)),
          update_expression: "ADD click_count :one SET click_url = :click_url",
          expression_attribute_values: { ":one" => 1, ":click_url" => click_url }
        )
      end

      def increment_summary(installment_id:, attribute:)
        client.update_item(
          table_name:,
          key: item_key(installment_id, SUMMARY_SORT_KEY),
          update_expression: "ADD #counter :one",
          expression_attribute_names: { "#counter" => attribute },
          expression_attribute_values: { ":one" => 1 }
        )
      end

      def item_key(installment_id, sort_key)
        { "pk" => partition_key(installment_id), "sk" => sort_key }
      end

      def timestamp
        Time.current.utc.iso8601(3)
      end
  end
end
