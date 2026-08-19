# frozen_string_literal: true

# Loads the Mongo engagement collections into the DynamoDB email_engagement
# table (gumroad-private#2158). Run phases in order, each from a console:
#
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_opens!
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_clicks!
#   Onetime::BackfillEmailEngagementDynamoTable.recompute_counters!  # rerun until it reports 0 adjustments
#   Onetime::BackfillEmailEngagementDynamoTable.verify!
#
# The dual-write flag must be on before the first phase starts: Mongo then
# strictly contains every live item, so overwriting on key collision is safe.
# Item phases checkpoint the last Mongo ObjectId in Redis and resume from it.
# Counter phases only read DynamoDB and write ADD deltas, so they are
# idempotent and converge even while live events keep incrementing.
class Onetime::BackfillEmailEngagementDynamoTable
  MONGO_BATCH_SIZE = 1_000
  DYNAMO_BATCH_SIZE = 25 # BatchWriteItem hard limit
  SCAN_PAGE_SIZE = 1_000
  MAX_WRITE_ATTEMPTS = 8
  OPENS_CURSOR_KEY = "onetime_backfill_email_engagement_opens_last_id"
  CLICKS_CURSOR_KEY = "onetime_backfill_email_engagement_clicks_last_id"

  class << self
    def backfill_opens!
      each_mongo_batch(CreatorEmailOpenEvent, OPENS_CURSOR_KEY) do |docs|
        write_items(docs.filter_map { open_item(_1) })
      end
    end

    def backfill_clicks!
      each_mongo_batch(CreatorEmailClickEvent, CLICKS_CURSOR_KEY) do |docs|
        write_items(docs.flat_map { click_items(_1) })
      end
    end

    # Tallies OPEN#/CLICKER#/CLICK# items per installment in one full scan and
    # corrects SUMMARY and URL# counters by the difference. Deltas (not
    # absolute writes) because live events keep incrementing concurrently.
    def recompute_counters!
      tallies = Hash.new { |h, k| h[k] = { opens: 0, clickers: 0, urls: Hash.new(0) } }
      current = Hash.new { |h, k| h[k] = { opens: 0, clickers: 0, urls: Hash.new(0) } }

      scan_all_items do |item|
        pk = item["pk"]
        sk = item["sk"]
        if sk == EmailEngagementDynamoStore::SUMMARY_SORT_KEY
          current[pk][:opens] = item["open_count"].to_i
          current[pk][:clickers] = item["click_count"].to_i
        elsif sk.start_with?("OPEN#")
          tallies[pk][:opens] += 1
        elsif sk.start_with?("CLICKER#")
          tallies[pk][:clickers] += 1
        elsif sk.start_with?("CLICK#")
          tallies[pk][:urls][item["click_url"]] += 1
        elsif sk.start_with?("URL#")
          current[pk][:urls][item["click_url"]] = item["click_count"].to_i
        end
      end

      adjustments = 0
      (tallies.keys | current.keys).each do |pk|
        adjustments += apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "open_count", tallies[pk][:opens] - current[pk][:opens])
        adjustments += apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "click_count", tallies[pk][:clickers] - current[pk][:clickers])
        (tallies[pk][:urls].keys | current[pk][:urls].keys).each do |url|
          adjustments += apply_delta(pk, store.url_sort_key(url), "click_count", tallies[pk][:urls][url] - current[pk][:urls][url], click_url: url)
        end
      end
      puts "#{adjustments} counter adjustments applied; rerun until this reports 0."
      adjustments
    end

    def verify!(sample_size: 1_000)
      mismatches = []
      CreatorEmailClickSummary.all.read(mode: :secondary_preferred).limit(sample_size).each do |summary|
        pk = store.partition_key(summary.installment_id)
        dynamo = store.client.get_item(
          table_name: store.table_name,
          key: { "pk" => pk, "sk" => EmailEngagementDynamoStore::SUMMARY_SORT_KEY }
        ).item || {}
        mongo_opens = CreatorEmailOpenEvent.where(installment_id: summary.installment_id).count
        expected = { clicks: summary.total_unique_clicks.to_i, opens: mongo_opens }
        actual = { clicks: dynamo["click_count"].to_i, opens: dynamo["open_count"].to_i }
        mismatches << { installment_id: summary.installment_id, expected:, actual: } if expected != actual
      end
      puts mismatches.empty? ? "All #{sample_size} sampled installments match." : "#{mismatches.size} mismatches: #{mismatches.first(20).inspect}"
      mismatches
    end

    private
      def store
        EmailEngagementDynamoStore
      end

      def each_mongo_batch(model, cursor_key)
        last_id = $redis.get(cursor_key)
        processed = 0
        loop do
          criteria = model.all.read(mode: :secondary_preferred).order(_id: :asc).limit(MONGO_BATCH_SIZE)
          criteria = criteria.where(_id: { "$gt" => BSON::ObjectId.from_string(last_id) }) if last_id
          docs = criteria.to_a
          break if docs.empty?

          yield docs
          processed += docs.size
          last_id = docs.last._id.to_s
          $redis.set(cursor_key, last_id)
          puts "#{model.name}: #{processed} docs this run, through #{last_id}" if (processed % 100_000).zero?
        end
        puts "#{model.name}: done, #{processed} docs this run."
      end

      def open_item(doc)
        return if doc.installment_id.blank? || doc.mailer_method.blank?

        first, last = timestamp_range(doc.open_timestamps, doc)
        {
          "pk" => store.partition_key(doc.installment_id),
          "sk" => store.open_sort_key(mailer_method: doc.mailer_method, mailer_args: doc.mailer_args.to_s),
          "mailer_method" => doc.mailer_method,
          "mailer_args" => doc.mailer_args.to_s,
          "open_count" => [doc.open_count.to_i, 1].max,
          "first_open_at" => first,
          "last_open_at" => last,
        }
      end

      def click_items(doc)
        return [] if doc.installment_id.blank? || doc.mailer_method.blank? || doc.click_url.blank?

        pk = store.partition_key(doc.installment_id)
        mailer_method = doc.mailer_method
        mailer_args = doc.mailer_args.to_s
        first, _last = timestamp_range(doc.click_timestamps, doc)
        [
          {
            "pk" => pk,
            "sk" => store.click_sort_key(mailer_method:, mailer_args:, click_url: doc.click_url),
            "mailer_method" => mailer_method,
            "mailer_args" => mailer_args,
            "click_url" => doc.click_url,
            "click_count" => [doc.click_count.to_i, 1].max,
            "first_click_at" => first,
          },
          {
            "pk" => pk,
            "sk" => store.clicker_sort_key(mailer_method:, mailer_args:),
            "mailer_method" => mailer_method,
            "mailer_args" => mailer_args,
            "first_click_at" => first,
          },
        ]
      end

      def timestamp_range(timestamps, doc)
        times = Array(timestamps).compact
        times = [doc._id.generation_time] if times.empty?
        [times.min.utc.iso8601(3), times.max.utc.iso8601(3)]
      end

      # Docs are processed in _id (chronological) order, so keeping the first
      # occurrence of a duplicate key (a re-clicked recipient's CLICKER#
      # marker, or a race-created duplicate Mongo doc) preserves the earliest
      # timestamps. BatchWriteItem rejects batches containing duplicate keys.
      def write_items(items)
        items.uniq { |item| [item["pk"], item["sk"]] }.each_slice(DYNAMO_BATCH_SIZE) do |slice|
          requests = slice.map { |item| { put_request: { item: } } }
          MAX_WRITE_ATTEMPTS.times do |attempt|
            response = store.client.batch_write_item(request_items: { store.table_name => requests })
            requests = response.unprocessed_items[store.table_name]
            break if requests.blank?
            raise "Unprocessed items remain after #{MAX_WRITE_ATTEMPTS} attempts" if attempt == MAX_WRITE_ATTEMPTS - 1
            sleep(2**attempt * 0.1)
          end
        end
      end

      def scan_all_items(&block)
        last_evaluated_key = nil
        loop do
          response = store.client.scan(
            table_name: store.table_name,
            limit: SCAN_PAGE_SIZE,
            exclusive_start_key: last_evaluated_key
          )
          response.items.each(&block)
          last_evaluated_key = response.last_evaluated_key
          break if last_evaluated_key.blank?
        end
      end

      def apply_delta(pk, sort_key, attribute, delta, click_url: nil)
        return 0 if delta.zero?

        update_expression = "ADD #counter :delta"
        values = { ":delta" => delta }
        if click_url
          update_expression += " SET click_url = if_not_exists(click_url, :click_url)"
          values[":click_url"] = click_url
        end
        store.client.update_item(
          table_name: store.table_name,
          key: { "pk" => pk, "sk" => sort_key },
          update_expression:,
          expression_attribute_names: { "#counter" => attribute },
          expression_attribute_values: values
        )
        1
      end
  end
end
