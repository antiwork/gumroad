# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Loads the Mongo engagement collections into the DynamoDB email_engagement
# table (gumroad-private#2158). Run phases in order, each from a console:
#
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_opens!
#   Onetime::BackfillEmailEngagementDynamoTable.backfill_clicks!
#   Onetime::BackfillEmailEngagementDynamoTable.recompute_counters!  # forked scan + deltas, prints progress
#   Onetime::BackfillEmailEngagementDynamoTable.recompute_installments_active_since!(scan_started_at)
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
  MAX_WRITE_ATTEMPTS = 8
  RECOMPUTE_PROCESSES = 8
  DRIFT_WINDOW_MARGIN = 15.minutes
  # Everything classify_item reads; OPEN#/CLICKER# items shrink to keys only.
  SCAN_PROJECTION = "pk, sk, click_url, open_count, click_count, click_pair_count"
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

    # Tallies OPEN#/CLICKER#/CLICK# items per installment across the whole
    # table and corrects SUMMARY and URL# counters by the difference. Deltas
    # (not absolute writes) because live events keep incrementing concurrently.
    # The scan forks worker processes: item deserialization is CPU-bound Ruby,
    # so the GIL rules out threads. processes: 1 scans inline. Catch drift
    # from events arriving mid-run with recompute_installments_active_since!.
    def recompute_counters!(processes: RECOMPUTE_PROCESSES)
      started_at = Time.current
      adjustments =
        if processes >= 2
          estimated_items = store.client.describe_table(table_name: store.table_name).table.item_count.to_i
          puts "Scanning ~#{estimated_items} items with #{processes} forked workers..."
          scan_segments_forked(processes, estimated_items)
        else
          stream_segment_deltas(segment: nil, total_segments: nil, per_segment_estimate: nil)
        end
      puts "Done in #{((Time.current - started_at) / 60).round} minutes: #{adjustments} counter adjustments applied. " \
           "Catch mid-run drift with recompute_installments_active_since!(Time.iso8601(\"#{started_at.utc.iso8601}\"))."
      adjustments
    end

    # Cheap drift pass: only installments with Mongo events since `time` can
    # have drifted during a full recompute; re-derive just those partitions.
    # The margin covers events whose Mongo doc landed just before the scan
    # started but whose DynamoDB writes straddled it (same handler, but the
    # scan can catch a torn view of item vs counter).
    def recompute_installments_active_since!(time)
      min_id = BSON::ObjectId.from_time(time - DRIFT_WINDOW_MARGIN)
      installment_ids = CreatorEmailOpenEvent.where(_id: { "$gte" => min_id }).distinct(:installment_id)
      installment_ids |= CreatorEmailClickEvent.where(_id: { "$gte" => min_id }).distinct(:installment_id)
      installment_ids = installment_ids.compact
      puts "#{installment_ids.size} installments with activity since #{time}."
      installment_ids.each { |installment_id| recompute_installment!(installment_id) }
      installment_ids.size
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
          pairs: click_rows.size,
          urls: click_rows.group_by { |_, _, url| url }.transform_values(&:size),
        }
        summary = store.client.get_item(
          table_name: store.table_name,
          key: { "pk" => pk, "sk" => EmailEngagementDynamoStore::SUMMARY_SORT_KEY },
          consistent_read: true
        ).item || {}
        dynamo = { opens: summary["open_count"].to_i, clicks: summary["click_count"].to_i, pairs: summary["click_pair_count"].to_i, urls: {} }
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

    # The gate compares DynamoDB against the Mongo documents (open docs and
    # click-pair docs). Mongo's stored total_unique_clicks is reported on
    # mismatch rows but never enforced: concurrent url-prefetch bursts have
    # historically inflated it past the true clicker count, and it drifts a
    # little from the pair-doc count for the same reason.
    def verify!(sample_size: 1_000)
      mismatches = []
      CreatorEmailClickSummary.all.read(mode: :secondary_preferred).limit(sample_size).each do |summary|
        pk = store.partition_key(summary.installment_id)
        dynamo = store.client.get_item(
          table_name: store.table_name,
          key: { "pk" => pk, "sk" => EmailEngagementDynamoStore::SUMMARY_SORT_KEY }
        ).item || {}
        expected = {
          opens: CreatorEmailOpenEvent.where(installment_id: summary.installment_id).count,
          # Deduplicated: the unique click_index was never built in production,
          # so the collection holds duplicate docs that DynamoDB's keyed items
          # collapse by design (10-30% of docs on large blasts).
          pairs: CreatorEmailClickEvent.where(installment_id: summary.installment_id)
                                       .pluck(:mailer_method, :mailer_args, :click_url).uniq.size,
        }
        actual = { opens: dynamo["open_count"].to_i, pairs: dynamo["click_pair_count"].to_i }
        next if expected == actual
        mismatches << { installment_id: summary.installment_id, expected:, actual:, mongo_stored_clicks: summary.total_unique_clicks.to_i }
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
        { opens: 0, clickers: 0, pairs: 0, urls: Hash.new(0) }
      end

      def classify_item(item, tally, current)
        sk = item["sk"]
        if sk == EmailEngagementDynamoStore::SUMMARY_SORT_KEY
          current[:opens] = item["open_count"].to_i
          current[:clickers] = item["click_count"].to_i
          current[:pairs] = item["click_pair_count"].to_i
        elsif sk.start_with?("OPEN#")
          tally[:opens] += 1
        elsif sk.start_with?("CLICKER#")
          tally[:clickers] += 1
        elsif sk.start_with?("CLICK#")
          tally[:pairs] += 1
          tally[:urls][item["click_url"]] += 1
        elsif sk.start_with?("URL#")
          current[:urls][item["click_url"]] = item["click_count"].to_i
        end
      end

      def apply_deltas(pk, tally, current)
        adjustments = apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "open_count", tally[:opens] - current[:opens])
        adjustments += apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "click_count", tally[:clickers] - current[:clickers])
        adjustments += apply_delta(pk, EmailEngagementDynamoStore::SUMMARY_SORT_KEY, "click_pair_count", tally[:pairs] - current[:pairs])
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

      # Forked, not threaded: the work is GIL-bound Ruby deserialization.
      # Failed segments retry one at a time — and with consistent reads, so a
      # crashed attempt's already-applied deltas are seen and not re-added
      # (the default eventually consistent scan doesn't read our own writes).
      def scan_segments_forked(processes, estimated_items)
        dir = Dir.mktmpdir("email_engagement_recompute")
        per_segment_estimate = [estimated_items / processes, 1].max
        GC.start # shrink copy-on-write breakage in the children
        waits = processes.times.map do |segment|
          [segment, fork_segment_worker(segment, processes, dir, per_segment_estimate)]
        end
        failed = waits.map { |segment, pid| [segment, Process.wait2(pid).last] }.reject { |_, status| status.success? }
        failed.each do |segment, status|
          puts "segment #{segment} failed (#{status}); retrying serially..."
          retry_status = Process.wait2(
            fork_segment_worker(segment, processes, dir, per_segment_estimate, attempt: 2, consistent_read: true)
          ).last
          raise "segment #{segment} failed twice: #{status}, then #{retry_status}" unless retry_status.success?
        end

        # Checkpointed running totals per attempt; a crashed attempt's applied
        # deltas still count (retries add only what the crash left undone).
        Dir.glob(File.join(dir, "segment-*.adjustments")).sum { |path| File.read(path).to_i }
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def fork_segment_worker(segment, total_segments, dir, per_segment_estimate, attempt: 1, consistent_read: false)
        Process.fork do
          store.client = nil # fresh connections post-fork
          path = File.join(dir, "segment-#{segment}.attempt#{attempt}.adjustments")
          checkpoint = ->(adjustments) { File.write(path, adjustments.to_s) }
          checkpoint.call(stream_segment_deltas(segment:, total_segments:, per_segment_estimate:, consistent_read:, checkpoint:))
          exit!(0)
        rescue => e
          warn "segment #{segment} crashed: #{e.class}: #{e.message}"
          exit!(1)
        end
      end

      # A scan returns each pk's items contiguously (LastEvaluatedKey is
      # (pk, sk), and a pk hashes into exactly one segment), so one
      # installment's tally completes before the next begins: flush deltas at
      # each pk boundary and memory stays flat at any table size. verify!
      # backstops the whole run regardless.
      def stream_segment_deltas(segment:, total_segments:, per_segment_estimate:, consistent_read: false, checkpoint: nil)
        adjustments = 0
        scanned = 0
        run_pk = nil
        tally = new_tally
        seen = new_tally
        flush = lambda do
          adjustments += apply_deltas(run_pk, tally, seen) if run_pk
          tally = new_tally
          seen = new_tally
        end

        last_evaluated_key = nil
        loop do
          params = {
            table_name: store.table_name,
            projection_expression: SCAN_PROJECTION,
            consistent_read:,
            exclusive_start_key: last_evaluated_key,
          }
          params.update(segment:, total_segments:) if segment
          response = store.client.scan(**params)
          response.items.each do |item|
            if item["pk"] != run_pk
              flush.call
              run_pk = item["pk"]
            end
            classify_item(item, tally, seen)
          end
          scanned_before = scanned
          scanned += response.items.size
          if per_segment_estimate && scanned / 1_000_000 > scanned_before / 1_000_000
            percent = [scanned * 100.0 / per_segment_estimate, 100.0].min
            puts format("segment %d: %d/~%d items (%.1f%%), %d adjustments", segment, scanned, per_segment_estimate, percent, adjustments)
            checkpoint&.call(adjustments)
          end
          last_evaluated_key = response.last_evaluated_key
          break if last_evaluated_key.blank?
        end
        flush.call
        adjustments
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
