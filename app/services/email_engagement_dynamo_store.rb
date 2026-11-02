# frozen_string_literal: true

# The store for creator email engagement (opens/clicks), on one DynamoDB table.
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
#
# Global secondary index OPEN_TIME_INDEX: hash `pk`, range `first_open_at` (S). Only OPEN# items
# carry `first_open_at`, so the index holds the opens and nothing else, ordered by first open. It
# lets a send side read one window of opens instead of the post's whole OPEN# prefix. Production
# and staging declare it in Terraform (gumroad-private#4213); `create_table!` declares it for dev,
# test and branch apps.
class EmailEngagementDynamoStore
  TABLE_BASE_NAME = "email_engagement"
  SUMMARY_SORT_KEY = "SUMMARY"
  BATCH_GET_LIMIT = 100
  BATCH_GET_MAX_ATTEMPTS = 5
  TRANSACT_CONFLICT_MAX_ATTEMPTS = 3
  TRANSACT_CONFLICT_BACKOFF = 0.02
  # A throttled SUMMARY item takes longer to clear than a conflict, so a throttled
  # transaction backs off for up to ~1.5s in total before raising.
  TRANSACT_THROTTLE_MAX_ATTEMPTS = 5
  TRANSACT_THROTTLE_BACKOFF = 0.1
  THROTTLE_CANCELLATION_CODES = ["ThrottlingError", "ProvisionedThroughputExceeded"].freeze
  # Reasons that leave a transaction worth retrying in place. Any other reason (a
  # validation error, an item collection limit) won't clear on retry, so it raises.
  RETRYABLE_CANCELLATION_CODES = (["TransactionConflict", "None"] + THROTTLE_CANCELLATION_CODES).freeze

  OPEN_TIME_INDEX = "pk-first_open_at-index"
  # What the open-time index carries besides its keys and the table's (pk, sk, first_open_at): the
  # two attributes a send side reads off an open. Must match the Terraform projection.
  OPEN_TIME_INDEX_ATTRIBUTES = ["mailer_method", "mailer_args"].freeze
  # DynamoDB Local builds the index in seconds; a real table's backfill can take hours, so setup gives
  # up after this long instead of hanging.
  OPEN_TIME_INDEX_READY_TIMEOUT_SECONDS = 600
  OPEN_TIME_INDEX_POLL_SECONDS = 2

  # A CLICKER# item is a few hundred bytes, so one 4KB read unit of a prefix walk returns well over
  # this many of them, while a keyed read costs a read unit per item. Below this ratio of clickers to
  # recipients asked about, reading the recipients' own items is the cheaper way to find the clickers.
  CLICKERS_PER_KEYED_READ = 8

  # A deadline-bound read gives up on a slow connect or socket read after this long, rather
  # than the SDK's default 60s read timeout and retries, so one stuck page cannot hold the caller.
  DEADLINE_READ_TIMEOUT_SECONDS = 0.3

  # Raised when a partitioned walk was given a deadline and could not reach the end of the
  # partition inside it, so a caller on a web request's budget can degrade instead of blocking.
  class ScanBudgetExceeded < StandardError; end

  # Raised by `create_table!` when the open-time index is not queryable in time. Not a
  # ResourceInUseException, so the setup callers that rescue that one still fail.
  class OpenTimeIndexNotReady < StandardError; end

  class << self
    attr_writer :client, :deadline_client

    def record_open(installment_id:, mailer_method:, mailer_args:)
      upsert_open_item(installment_id: installment_id.to_i, mailer_method:, mailer_args:)
    end

    def record_click(installment_id:, mailer_method:, mailer_args:, click_url:)
      installment_id = installment_id.to_i
      recipient = recipient_digest(mailer_method:, mailer_args:)

      # Each of these is one TransactWrite so a retry after a mid-flight
      # failure cannot skip derived counters. A duplicate same-url click
      # cancels all three on ConditionalCheckFailed and counts nothing.
      commit_click_and_counters(installment_id:, mailer_method:, mailer_args:, click_url:, recipient:)
      commit_clicker_and_count(installment_id:, mailer_method:, mailer_args:, recipient:)
      ensure_open_item(installment_id:, mailer_method:, mailer_args:)
    end

    def client
      # An explicit endpoint is always passed: the global Aws.config endpoint
      # points at MinIO in development and test, and the SDK raises at
      # construction when the option is present but nil.
      @client ||= Aws::DynamoDB::Client.new(endpoint:)
    end

    def deadline_client
      @deadline_client ||= Aws::DynamoDB::Client.new(
        endpoint:,
        http_open_timeout: DEADLINE_READ_TIMEOUT_SECONDS,
        http_read_timeout: DEADLINE_READ_TIMEOUT_SECONDS,
        retry_limit: 0,
        max_attempts: 1,
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
    def summary(installment_id)
      item = client.get_item(table_name:, key: item_key(installment_id, SUMMARY_SORT_KEY)).item
      summary_from_item(item)
    end

    def summaries(installment_ids)
      ids = installment_ids.map(&:to_i).uniq
      return {} if ids.empty?

      counts = {}
      batch_get_items(ids.map { |id| item_key(id, SUMMARY_SORT_KEY) }).each do |item|
        counts[item["pk"].to_i] = summary_from_item(item)
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

      # Distinct stored URLs can share a display form (http vs https, www), so sum them.
      items.each_with_object({}) do |item, counts|
        url = display_url(item["click_url"].to_s)
        next if url.blank?
        counts[url] = counts.fetch(url, 0) + item["click_count"].to_i
      end
    end

    # Purchase ids of the recipients who clicked this installment's email at least
    # once. Only purchase-keyed clicks can be mapped back to a buyer: the digest in
    # the sort key is one-way, and a follower or affiliate click carries that record's
    # id in its args, not a purchase id.
    def clicked_recipient_purchase_ids(installment_id)
      partition_items(installment_id, "CLICKER#").filter_map { |item| purchase_id_from_item(item) }.uniq
    end

    # Recipient record ids of the people who opened this installment's email, split by the kind
    # of record the send addressed them as. Opens are recorded for every post type, including the
    # follower and affiliate recipients a purchase-keyed lookup cannot see, so a caller that needs
    # recipient emails (rather than buyers) has to resolve all three. A click also writes the OPEN
    # item, so a clicker counts as an opener.
    def opened_recipient_ids(installment_id, deadline: nil)
      ids = { purchase_ids: [], follower_ids: [], affiliate_ids: [] }
      partition_items(installment_id, "OPEN#", deadline:).each do |item|
        id = recipient_id_from_item(item)
        next if id.nil?

        mailer_method = item["mailer_method"].to_s
        if mailer_method.end_with?(EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD)
          ids[:purchase_ids] << id
        elsif mailer_method.end_with?(EmailEventInfo::FOLLOWER_INSTALLMENT_MAILER_METHOD)
          ids[:follower_ids] << id
        elsif mailer_method.end_with?(EmailEventInfo::DIRECT_AFFILIATE_INSTALLMENT_MAILER_METHOD)
          ids[:affiliate_ids] << id
        end
      end
      ids.transform_values(&:uniq)
    end

    # The buyer half of the same walk, for the purchase-keyed callers (the "Has opened" filter and
    # the purchase-backed non-opener set). A click also creates the open item, so a clicker counts
    # as an opener.
    def opened_recipient_purchase_ids(installment_id)
      partition_items(installment_id, "OPEN#").filter_map { |item| purchase_id_from_item(item) }.uniq
    end

    # The per-recipient opens of a post's email, as a send side needs them: the buyer, the digest that
    # identifies that recipient's send (and is also their click key), and the first open. A delay that
    # runs from each recipient's own open is read off `first_open_at`.
    #
    # Read from OPEN_TIME_INDEX, where `opened_after` / `opened_before` bound `first_open_at`
    # inclusively in the key condition, so only the opens inside the window are read (and paid for).
    # Callers keep their own window check.
    def purchase_open_records(installment_id, deadline: nil, opened_after: nil, opened_before: nil)
      key_condition = "pk = :pk"
      values = { ":pk" => partition_key(installment_id) }
      # `first_open_at` is a fixed-width millisecond ISO8601 UTC string, so string order is time order
      # and the bounds compare as strings. Truncating to the millisecond never narrows the window:
      # `first_open_at` is stored to the millisecond.
      values[":opened_after"] = opened_after.utc.iso8601(3) if opened_after
      values[":opened_before"] = opened_before.utc.iso8601(3) if opened_before
      if opened_after && opened_before
        # BETWEEN with its bounds out of order is a ValidationException, not an empty result.
        return [] if values[":opened_after"] > values[":opened_before"]

        key_condition += " AND first_open_at BETWEEN :opened_after AND :opened_before"
      elsif opened_after
        key_condition += " AND first_open_at >= :opened_after"
      elsif opened_before
        key_condition += " AND first_open_at <= :opened_before"
      end

      params = { table_name:, index_name: OPEN_TIME_INDEX, key_condition_expression: key_condition, expression_attribute_values: values }
      query_all(params, deadline:).filter_map do |item|
        purchase_id = purchase_id_from_item(item)
        first_open_at = parse_timestamp(item["first_open_at"])
        next if purchase_id.nil? || first_open_at.nil?

        { purchase_id:, recipient_digest: item["sk"].to_s.delete_prefix("OPEN#"), first_open_at: }
      end
    end

    # Whether this recipient has clicked the post's email at least once. The digest is the one the
    # caller walked off the OPEN# item, so a caller that already knows its openers needs no lookup per
    # recipient to leave the clickers out.
    def clicked?(installment_id:, recipient_digest:)
      return false if recipient_digest.blank?

      client.get_item(table_name:, key: item_key(installment_id, "CLICKER##{recipient_digest}")).item.present?
    end

    # The digests of the recipients who clicked, for a caller walking the opens that wants to drop the
    # clickers in one pass. Same digest space as `purchase_open_records`.
    def clicked_recipient_digests(installment_id, deadline: nil)
      partition_items(installment_id, "CLICKER#", deadline:).filter_map { |item| item["sk"].to_s.delete_prefix("CLICKER#").presence }
    end

    # Which of these recipient digests have clicked, read the cheaper way for the size of the ask. A
    # post nobody clicked costs the SUMMARY read alone. A few recipients against many clickers (the
    # daily scan's window) read only those recipients' CLICKER# items; anything larger walks the
    # CLICKER# prefix once, which is cheaper per clicker than a keyed read each.
    def clicked_recipient_digests_among(installment_id, digests)
      digests = digests.compact_blank.uniq
      return Set.new if digests.empty?

      click_count = summary(installment_id)[:click_count]
      return Set.new if click_count.zero?

      if digests.size * CLICKERS_PER_KEYED_READ <= click_count
        keys = digests.map { item_key(installment_id, "CLICKER##{_1}") }
        batch_get_items(keys, projection_expression: "sk").to_set { _1["sk"].to_s.delete_prefix("CLICKER#") }
      else
        clicked_recipient_digests(installment_id).to_set & digests
      end
    end

    # A table that already exists from before the open-time index (a dev or test container, a branch
    # app) gets the index added, then the ResourceInUseException is re-raised for the callers that
    # rescue it. Without the index, `purchase_open_records` fails on that table. Either way this
    # returns or re-raises only once the index is ACTIVE.
    def create_table!
      client.create_table(
        table_name:,
        attribute_definitions: [
          { attribute_name: "pk", attribute_type: "S" },
          { attribute_name: "sk", attribute_type: "S" },
          { attribute_name: "first_open_at", attribute_type: "S" },
        ],
        key_schema: [
          { attribute_name: "pk", key_type: "HASH" },
          { attribute_name: "sk", key_type: "RANGE" },
        ],
        global_secondary_indexes: [open_time_index_definition],
        billing_mode: "PAY_PER_REQUEST"
      )
      ensure_open_time_index!
    rescue Aws::DynamoDB::Errors::ResourceInUseException
      ensure_open_time_index!
      raise
    end

    # Key derivation is public because the historical data was backfilled with
    # these exact digests; changing it would orphan every existing item.
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
      def endpoint
        GlobalConfig.get("DYNAMODB_ENDPOINT", "https://dynamodb.#{AWS_DEFAULT_REGION}.amazonaws.com")
      end

      # Every item under one sort-key prefix in an installment's partition. The items are small
      # and one exists per recipient (or per recipient + url), so a six-figure post pages through
      # this a megabyte at a time. Callers with a budget pass `deadline:` and get a bounded client
      # that gives up (ScanBudgetExceeded) instead of blocking the request.
      def partition_items(installment_id, prefix, deadline: nil)
        query_all(
          {
            table_name:,
            key_condition_expression: "pk = :pk AND begins_with(sk, :prefix)",
            expression_attribute_values: { ":pk" => partition_key(installment_id), ":prefix" => prefix },
          },
          deadline:
        )
      end

      # Every page of one query. Callers with a budget pass `deadline:` and get a bounded client that
      # gives up (ScanBudgetExceeded) instead of blocking the request.
      def query_all(params, deadline: nil)
        items = []
        exclusive_start_key = nil
        loop do
          raise ScanBudgetExceeded if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          page_params = exclusive_start_key.present? ? params.merge(exclusive_start_key:) : params
          response = deadline ? deadline_query(page_params) : client.query(page_params)
          items.concat(response.items)
          exclusive_start_key = response.last_evaluated_key
          break if exclusive_start_key.blank?
        end
        items
      end

      # BatchGetItem in slices of BATCH_GET_LIMIT, retrying the keys DynamoDB leaves unprocessed.
      def batch_get_items(keys, projection_expression: nil)
        items = []
        keys.each_slice(BATCH_GET_LIMIT) do |slice|
          request = { keys: slice }
          request[:projection_expression] = projection_expression if projection_expression
          request_items = { table_name => request }
          BATCH_GET_MAX_ATTEMPTS.times do |attempt|
            response = client.batch_get_item(request_items:)
            items.concat(response.responses[table_name] || [])
            request_items = response.unprocessed_keys
            break if request_items.blank?
            raise "Unprocessed keys remain after #{BATCH_GET_MAX_ATTEMPTS} BatchGetItem attempts" if attempt == BATCH_GET_MAX_ATTEMPTS - 1
            sleep(2**attempt * 0.1)
          end
        end
        items
      end

      def open_time_index_definition
        {
          index_name: OPEN_TIME_INDEX,
          key_schema: [
            { attribute_name: "pk", key_type: "HASH" },
            { attribute_name: "first_open_at", key_type: "RANGE" },
          ],
          projection: { projection_type: "INCLUDE", non_key_attributes: OPEN_TIME_INDEX_ATTRIBUTES },
        }
      end

      # DescribeTable lists an index as soon as it starts building, but AWS rejects queries on it until
      # it is ACTIVE. Running setup again after a timeout resumes the wait on the same build.
      def ensure_open_time_index!
        status = open_time_index_status
        add_open_time_index if status.nil?

        waited = 0
        until status == "ACTIVE"
          if waited >= OPEN_TIME_INDEX_READY_TIMEOUT_SECONDS
            raise OpenTimeIndexNotReady, "#{OPEN_TIME_INDEX} on #{table_name} is not ACTIVE after #{waited}s; run setup again once it is"
          end
          sleep(OPEN_TIME_INDEX_POLL_SECONDS)
          waited += OPEN_TIME_INDEX_POLL_SECONDS
          status = open_time_index_status
        end
      end

      def add_open_time_index
        client.update_table(
          table_name:,
          attribute_definitions: [
            { attribute_name: "pk", attribute_type: "S" },
            { attribute_name: "first_open_at", attribute_type: "S" },
          ],
          global_secondary_index_updates: [{ create: open_time_index_definition }]
        )
      rescue Aws::DynamoDB::Errors::ResourceInUseException
        # Another setup's UpdateTable got there first. Escaping here would skip the wait, because the
        # setup callers rescue this class.
        nil
      end

      def open_time_index_status
        client.describe_table(table_name:).table.global_secondary_indexes.to_a.find { _1.index_name == OPEN_TIME_INDEX }&.index_status
      end

      # This client does not retry, so a timed-out, throttled or failed page means the walk cannot
      # finish inside the caller's budget. A caller without a deadline still sees the raw error.
      def deadline_query(params)
        deadline_client.query(params)
      rescue Seahorse::Client::NetworkingError, Aws::DynamoDB::Errors::ServiceError
        raise ScanBudgetExceeded
      end

      # The item keeps the mailer method and args its digest was built from. Args are
      # "[<purchase_id|follower_id|affiliate_id>, <post_id>]" (see PostSendgridApi and
      # PostResendApi) and the method says which of the three the first integer is.
      def recipient_id_from_item(item)
        item["mailer_args"].to_s[/\d+/]&.to_i
      end

      def purchase_id_from_item(item)
        mailer_method = item["mailer_method"].to_s
        return nil unless mailer_method.end_with?(EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD)

        recipient_id_from_item(item)
      end

      def upsert_open_item(installment_id:, mailer_method:, mailer_args:)
        return if ensure_open_item(installment_id:, mailer_method:, mailer_args:)

        now = timestamp
        client.update_item(
          table_name:,
          key: item_key(installment_id, open_sort_key(mailer_method:, mailer_args:)),
          update_expression: "ADD open_count :one " \
                             "SET mailer_method = :mailer_method, mailer_args = :mailer_args, " \
                             "last_open_at = :now",
          expression_attribute_values: { ":one" => 1, ":mailer_method" => mailer_method, ":mailer_args" => mailer_args, ":now" => now }
        )
      end

      # Creates the open item only if absent, without touching an existing item's
      # open_count: a click implies an open even when no open event arrived.
      # Bundled with the summary increment so a retry cannot leave unique opens undercounted.
      def ensure_open_item(installment_id:, mailer_method:, mailer_args:)
        now = timestamp
        transact_unless_exists(
          [
            {
              put: {
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
                condition_expression: "attribute_not_exists(pk)",
              }
            },
            summary_increment(installment_id, "open_count"),
          ]
        )
      end

      def commit_click_and_counters(installment_id:, mailer_method:, mailer_args:, click_url:, recipient:)
        transact_unless_exists(
          [
            {
              put: {
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
                condition_expression: "attribute_not_exists(pk)",
              }
            },
            {
              update: {
                table_name:,
                key: item_key(installment_id, url_sort_key(click_url)),
                update_expression: "ADD click_count :one SET click_url = :click_url",
                expression_attribute_values: { ":one" => 1, ":click_url" => click_url },
              }
            },
            summary_increment(installment_id, "click_pair_count"),
          ]
        )
      end

      def commit_clicker_and_count(installment_id:, mailer_method:, mailer_args:, recipient:)
        transact_unless_exists(
          [
            {
              put: {
                table_name:,
                item: {
                  "pk" => partition_key(installment_id),
                  "sk" => "CLICKER##{recipient}",
                  "mailer_method" => mailer_method,
                  "mailer_args" => mailer_args,
                  "first_click_at" => timestamp,
                },
                condition_expression: "attribute_not_exists(pk)",
              }
            },
            summary_increment(installment_id, "click_count"),
          ]
        )
      end

      def summary_increment(installment_id, attribute)
        {
          update: {
            table_name:,
            key: item_key(installment_id, SUMMARY_SORT_KEY),
            update_expression: "ADD #counter :one",
            expression_attribute_names: { "#counter" => attribute },
            expression_attribute_values: { ":one" => 1 },
          }
        }
      end

      # Every open and click for one post increments that post's single SUMMARY item, so a
      # callback burst contends on it and DynamoDB throttles it. Absorb conflicts and
      # throttles here rather than spending the event's few Sidekiq retries on them.
      def transact_unless_exists(transact_items)
        attempts = 0
        throttled = false
        begin
          client.transact_write_items(transact_items:)
          true
        rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
          codes = cancellation_codes(e)
          # Only the put is conditional and these items are never deleted, so a failed
          # condition is a duplicate whatever else cancelled the transaction.
          return false if codes.include?("ConditionalCheckFailed")
          raise unless retryable_cancellation?(codes)

          attempts += 1
          # Once throttled, keep the throttle budget even if a conflict cancels a later attempt.
          throttled ||= codes.intersect?(THROTTLE_CANCELLATION_CODES)
          max_attempts, backoff = throttled ? [TRANSACT_THROTTLE_MAX_ATTEMPTS, TRANSACT_THROTTLE_BACKOFF] : [TRANSACT_CONFLICT_MAX_ATTEMPTS, TRANSACT_CONFLICT_BACKOFF]
          raise if attempts >= max_attempts
          # Jittered so contending writers don't line up again on the next attempt.
          sleep(rand * backoff * 2**(attempts - 1))
          retry
        end
      end

      def retryable_cancellation?(codes)
        (codes.include?("TransactionConflict") || codes.intersect?(THROTTLE_CANCELLATION_CODES)) &&
          codes.all? { |code| RETRYABLE_CANCELLATION_CODES.include?(code) }
      end

      # Stubbed clients raise with empty data, so fall back to the per-item reason
      # list the service embeds in the message.
      def cancellation_codes(error)
        codes = error.data.try(:cancellation_reasons).to_a.map(&:code)
        return codes if codes.any?
        error.message.to_s[/\[([^\]]+)\]\z/, 1].to_s.split(",").map(&:strip)
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

      # `first_open_at` is written as an ISO8601 string. An item whose value cannot be read is dropped
      # by the caller rather than sending on a clock that cannot be established.
      def parse_timestamp(value)
        Time.zone.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
  end
end
