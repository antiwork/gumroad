# frozen_string_literal: true

# Loads the Mongo engagement collections into the DynamoDB email_engagement
# table (gumroad-private#2158). Run phases in order, each from a console:
#
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_opens!
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_clicks!
#   Onetime::BackfillEmailEngagementDynamoTable.recompute_counters!  # rerun until it reports 0 adjustments
#   Onetime::BackfillEmailEngagementDynamoTable.verify!
#
# Or pilot a single seller (or a single installment) first:
#
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_seller!(seller_id)
#   Onetime::BackfillEmailEngagementDynamoTable.verify_seller!(seller_id)
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_installment!(installment_id)
#
# The dual-write flag must be on before the first phase starts: Mongo then
# strictly contains every live item, so overwriting on key collision is safe.
# Item phases checkpoint the last Mongo ObjectId in Redis and resume from it.
# Counter phases only read DynamoDB and write ADD deltas, so they are
# idempotent and converge even while live events keep incrementing.
class Onetime::BackfillEmailEngagementDynamoTable
  MONGO_BATCH_SIZE = 1_000
  DYNAMO_BATCH_SIZE = 25 # BatchWriteItem hard limit
  PROGRESS_INTERVAL = 100_000 # docs between progress lines
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
      tallies = Hash.new { |h, k| h[k] = new_tally }
      current = Hash.new { |h, k| h[k] = new_tally }
      scan_all_items { |item| classify_item(item, tallies[item["pk"]], current[item["pk"]]) }

      adjustments = (tallies.keys | current.keys).sum { |pk| apply_deltas(pk, tallies[pk], current[pk]) }
      puts "#{adjustments} counter adjustments applied; rerun until this reports 0."
      adjustments
    end

    # Pilot: backfill a single seller's installments end-to-end (items plus a
    # per-partition counter recompute), then compare with verify_seller!.
    # Rerunnable at any time; the full backfill later re-puts identical items.
    def backfill_seller!(seller_id)
      installment_ids = Installment.where(seller_id:).ids
      doc_counts = installment_ids.index_with do |installment_id|
        CreatorEmailOpenEvent.where(installment_id:).count + CreatorEmailClickEvent.where(installment_id:).count
      end
      total_docs = doc_counts.values.sum
      processed_docs = 0

      installment_ids.each_with_index do |installment_id, index|
        backfill_installment!(installment_id, quiet: true)
        processed_docs += doc_counts[installment_id]
        percent = total_docs.zero? ? 100.0 : processed_docs * 100.0 / total_docs
        puts format("[%d/%d] installment %d done (%d docs) — %.1f%% (%d/%d docs)",
                    index + 1, installment_ids.size, installment_id, doc_counts[installment_id],
                    percent, processed_docs, total_docs)
      end
      puts "Backfilled #{installment_ids.size} installments for seller #{seller_id}; compare with verify_seller!(#{seller_id})."
      installment_ids.size
    end

    # Backfill a single installment (items plus its counter recompute).
    def backfill_installment!(installment_id, quiet: false)
      docs = 0
      progress = lambda do |batch|
        crossed = docs / 100_000 > (docs - batch.size) / 100_000
        puts "  installment #{installment_id}: #{docs} docs..." if crossed
      end
      CreatorEmailOpenEvent.where(installment_id:).read(mode: :secondary_preferred).each_slice(MONGO_BATCH_SIZE) do |batch|
        write_items(batch.filter_map { open_item(_1) })
        docs += batch.size
        progress.call(batch)
      end
      CreatorEmailClickEvent.where(installment_id:).read(mode: :secondary_preferred).each_slice(MONGO_BATCH_SIZE) do |batch|
        write_items(batch.flat_map { click_items(_1) })
        docs += batch.size
        progress.call(batch)
      end
      recompute_installment!(installment_id)
      puts "Backfilled installment #{installment_id} (#{docs} docs); counters recomputed." unless quiet
      docs
    end

    # Three-way comparison per installment. The invariant is DynamoDB ==
    # counts derived from the Mongo documents; Mongo's stored click summary is
    # reported alongside but is not the correctness bar — its cache-guarded
    # counters have drifted historically.
    def verify_seller!(seller_id)
      mismatches = []
      Installment.where(seller_id:).ids.each do |installment_id|
        pk = store.partition_key(installment_id)
        mongo_opens = CreatorEmailOpenEvent.where(installment_id:).count
        click_rows = CreatorEmailClickEvent.where(installment_id:).pluck(:mailer_method, :mailer_args, :click_url).uniq
        next if mongo_opens.zero? && click_rows.empty?

        mongo_docs = {
          opens: mongo_opens,
          clicks: click_rows.map { |mailer_method, mailer_args, _| [mailer_method, mailer_args] }.uniq.size,
          urls: click_rows.group_by { |_, _, url| url }.transform_values(&:size),
        }
        summary = store.client.get_item(
          table_name: store.table_name,
          key: { "pk" => pk, "sk" => EmailEngagementDynamoStore::SUMMARY_SORT_KEY },
          consistent_read: true
        ).item || {}
        dynamo = { opens: summary["open_count"].to_i, clicks: summary["click_count"].to_i, urls: {} }
        query_partition(pk, sk_prefix: "URL#") { |item| dynamo[:urls][item["click_url"]] = item["click_count"].to_i }

        next if dynamo == mongo_docs
        mismatches << {
          installment_id:,
          dynamo:,
          mongo_docs:,
          mongo_stored_clicks: CreatorEmailClickSummary.where(installment_id:).last&.total_unique_clicks.to_i,
        }
      end
      puts mismatches.empty? ? "Seller #{seller_id}: every installment matches the Mongo documents." : "#{mismatches.size} mismatches: #{mismatches.first(20).inspect}"
      mismatches
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
        # The denominator is snapshotted once per backfill (NX) because live
        # dual-writes keep growing the collection; the cumulative counter
        # advances atomically with the cursor, so the percentage survives
        # restarts with at most one re-processed batch of drift. Chasing docs
        # written after the snapshot can push the final percentage slightly
        # past 100 — that's the swept tail, not an error.
        $redis.set("#{cursor_key}_total", model.collection.estimated_document_count, nx: true)
        total = $redis.get("#{cursor_key}_total").to_i
        run_started_at = Time.current
        run_processed = 0

        loop do
          criteria = model.all.read(mode: :secondary_preferred).order(_id: :asc).limit(MONGO_BATCH_SIZE)
          criteria = criteria.where(_id: { "$gt" => BSON::ObjectId.from_string(last_id) }) if last_id
          docs = criteria.to_a
          break if docs.empty?

          yield docs
          run_processed += docs.size
          last_id = docs.last._id.to_s
          _, cumulative = $redis.multi do |transaction|
            transaction.set(cursor_key, last_id)
            transaction.incrby("#{cursor_key}_processed", docs.size)
          end
          report_progress(model, cumulative.to_i, total, run_processed, run_started_at) if (run_processed % PROGRESS_INTERVAL).zero?
        end
        puts "#{model.name}: done, #{run_processed} docs this run."
      end

      def report_progress(model, cumulative, total, run_processed, run_started_at)
        percent = total.zero? ? 100.0 : cumulative * 100.0 / total
        elapsed = Time.current - run_started_at
        rate = elapsed.positive? ? run_processed / elapsed : 0
        remaining_hours = rate.positive? ? [(total - cumulative), 0].max / rate / 1.hour : 0
        puts format("%s: %d/%d (%.1f%%) — %d docs/s, ~%.1fh remaining", model.name, cumulative, total, percent, rate, remaining_hours)
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

      def new_tally
        { opens: 0, clickers: 0, urls: Hash.new(0) }
      end

      def classify_item(item, tally, current)
        sk = item["sk"]
        if sk == EmailEngagementDynamoStore::SUMMARY_SORT_KEY
          current[:opens] = item["open_count"].to_i
          current[:clickers] = item["click_count"].to_i
        elsif sk.start_with?("OPEN#")
          tally[:opens] += 1
        elsif sk.start_with?("CLICKER#")
          tally[:clickers] += 1
        elsif sk.start_with?("CLICK#")
          tally[:urls][item["click_url"]] += 1
        elsif sk.start_with?("URL#")
          current[:urls][item["click_url"]] = item["click_count"].to_i
        end
      end

      def apply_deltas(pk, tally, current)
        adjustments = apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "open_count", tally[:opens] - current[:opens])
        adjustments += apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "click_count", tally[:clickers] - current[:clickers])
        (tally[:urls].keys | current[:urls].keys).each do |url|
          adjustments += apply_delta(pk, store.url_sort_key(url), "click_count", tally[:urls][url] - current[:urls][url], click_url: url)
        end
        adjustments
      end

      def recompute_installment!(installment_id)
        pk = store.partition_key(installment_id)
        tally = new_tally
        current = new_tally
        query_partition(pk) { |item| classify_item(item, tally, current) }
        apply_deltas(pk, tally, current)
      end

      def query_partition(pk, sk_prefix: nil, &block)
        key_condition = "pk = :pk"
        values = { ":pk" => pk }
        if sk_prefix
          key_condition += " AND begins_with(sk, :sk_prefix)"
          values[":sk_prefix"] = sk_prefix
        end
        last_evaluated_key = nil
        loop do
          response = store.client.query(
            table_name: store.table_name,
            key_condition_expression: key_condition,
            expression_attribute_values: values,
            exclusive_start_key: last_evaluated_key,
            consistent_read: true
          )
          response.items.each(&block)
          last_evaluated_key = response.last_evaluated_key
          break if last_evaluated_key.blank?
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
