# frozen_string_literal: true

# Dual-write adapter for the DynamoDB table replacing the CreatorEmailOpenEvent /
# CreatorEmailClickEvent / CreatorEmailClickSummary Mongo collections.
#
# Partition key `pk` (S, the stringified installment id), sort key `sk` (S), one of:
#   SUMMARY                    — open_count / click_count / click_pair_count counters;
#                                click_pair_count (unique recipient+url pairs) is what the
#                                dashboard's "Clicks" has historically shown, click_count is
#                                true unique clickers
#   OPEN#<recipient>           — one item per recipient who opened
#   CLICKER#<recipient>        — claims the recipient's first click; drives click_count
#   CLICK#<recipient>#<url>    — one item per recipient + url first click
#   URL#<url>                  — unique-click total for one url
# <recipient> and <url> are SHA256 hex digests (raw values are attributes on the
# items). Per-url totals are separate items rather than a map on SUMMARY so
# link-heavy posts can't grow SUMMARY toward the 400KB item cap.
class EmailEngagementDynamoStore
  TABLE_BASE_NAME = "email_engagement"
  SUMMARY_SORT_KEY = "SUMMARY"
  DUAL_WRITE_FEATURE = :email_engagement_dynamodb_dual_write
  READ_FEATURE = :email_engagement_dynamodb_reads
  BATCH_GET_LIMIT = 100
  BATCH_GET_MAX_ATTEMPTS = 5

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

        # A repeat click of the same url by the same recipient counts nothing,
        # matching the Mongo path's early return.
        next unless put_click_item(installment_id:, mailer_method:, mailer_args:, click_url:, recipient:)

        increment_url_click_count(installment_id:, click_url:)
        increment_summary(installment_id:, attribute: "click_pair_count")
        # The conditional marker put is both the "has this recipient clicked
        # anything?" check and the claim, so concurrent first clicks on
        # different urls can't double-increment the counter.
        if put_clicker_marker(installment_id:, mailer_method:, mailer_args:, recipient:)
          increment_summary(installment_id:, attribute: "click_count")
        end
        # A click implies an open; compensates for blocked tracking pixels.
        ensure_open_item(installment_id:, mailer_method:, mailer_args:)
      end
    end

    def client
      # An explicit endpoint is always passed: the global Aws.config endpoint
      # points at MinIO in development and test, and the SDK raises at
      # construction when the option is present but nil.
      @client ||= Aws::DynamoDB::Client.new(
        endpoint: GlobalConfig.get("DYNAMODB_ENDPOINT", "https://dynamodb.#{AWS_DEFAULT_REGION}.amazonaws.com")
      )
    end

    def table_name
      "#{table_prefix}#{TABLE_BASE_NAME}"
    end

    # Production and staging default to the Terraform-owned <env>- tables;
    # DYNAMODB_TABLE_PREFIX overrides for dev lanes and branch apps.
    def table_prefix
      ENV["DYNAMODB_TABLE_PREFIX"].presence ||
        (Rails.env.production? || Rails.env.staging? ? "#{Rails.env}-" : "")
    end

    # Staging and production tables are Terraform-owned (antiwork/infrastructure#998)
    # and deletion-protected; this bootstrap is for dev, test, and branch apps.
    # DynamoDB is the primary store outside production: dual writes always
    # on, reads always served from DynamoDB. Production stays flag-controlled
    # until the Mongo decommission completes.
    def reads_enabled?
      !Rails.env.production? || Feature.active?(READ_FEATURE)
    end

    def dual_writes_enabled?
      !Rails.env.production? || Feature.active?(DUAL_WRITE_FEATURE)
    end

    def summary(installment_id)
      item = client.get_item(table_name:, key: item_key(installment_id, SUMMARY_SORT_KEY)).item
      summary_from_item(item)
    end

    def summaries(installment_ids)
      ids = installment_ids.map(&:to_i).uniq
      return {} if ids.empty?

      counts = {}
      ids.each_slice(BATCH_GET_LIMIT) do |slice|
        request_items = { table_name => { keys: slice.map { |id| item_key(id, SUMMARY_SORT_KEY) } } }
        BATCH_GET_MAX_ATTEMPTS.times do |attempt|
          response = client.batch_get_item(request_items:)
          (response.responses[table_name] || []).each do |item|
            counts[item["pk"].to_i] = summary_from_item(item)
          end
          request_items = response.unprocessed_keys
          break if request_items.blank?
          raise "Unprocessed keys remain after #{BATCH_GET_MAX_ATTEMPTS} BatchGetItem attempts" if attempt == BATCH_GET_MAX_ATTEMPTS - 1
          sleep(2**attempt * 0.1)
        end
      end
      ids.index_with { |id| counts[id] || summary_from_item(nil) }
    end

    def url_click_counts(installment_id)
      items = []
      exclusive_start_key = nil
      loop do
        params = {
          table_name:,
          key_condition_expression: "pk = :pk AND begins_with(sk, :prefix)",
          expression_attribute_values: {
            ":pk" => partition_key(installment_id),
            ":prefix" => "URL#",
          },
        }
        params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key.present?
        response = client.query(params)
        items.concat(response.items)
        exclusive_start_key = response.last_evaluated_key
        break if exclusive_start_key.blank?
      end

      items.each_with_object({}) do |item, counts|
        url = display_url(item["click_url"].to_s)
        next if url.blank?
        counts[url] = item["click_count"].to_i
      end
    end

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

    def clicker_sort_key(mailer_method:, mailer_args:)
      "CLICKER##{recipient_digest(mailer_method:, mailer_args:)}"
    end

    def url_sort_key(click_url)
      "URL##{url_digest(click_url)}"
    end

    private
      def with_dual_write_guard
        return unless dual_writes_enabled?
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

      def put_clicker_marker(installment_id:, mailer_method:, mailer_args:, recipient:)
        client.put_item(
          table_name:,
          item: {
            "pk" => partition_key(installment_id),
            "sk" => "CLICKER##{recipient}",
            "mailer_method" => mailer_method,
            "mailer_args" => mailer_args,
            "first_click_at" => timestamp,
          },
          condition_expression: "attribute_not_exists(pk)"
        )
        true
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        false
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

      def summary_from_item(item)
        {
          open_count: item&.[]("open_count").to_i,
          click_count: item&.[]("click_count").to_i,
          click_pair_count: item&.[]("click_pair_count").to_i,
        }
      end

      def display_url(url)
        url.gsub(/&#46;/, ".").sub(%r{\Ahttps?://}i, "").sub(/\Awww\./i, "")
      end

      def timestamp
        Time.current.utc.iso8601(3)
      end
  end
end
