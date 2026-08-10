# frozen_string_literal: true

require "spec_helper"

describe RecoverStrandedBuyersJob do
  let(:candidate) do
    {
      email: "stranded@example.com",
      purchaser_external_id: "ext-123",
      settled_purchases: 5,
      blocked_at: 2.months.ago,
      block_type: PlatformBlock::TYPES[:browser_guid],
      failed_at: 1.day.ago,
      attempts: 3,
    }
  end

  def recovery_result(verdict, reason, cleared: [], skipped: [], dry_run: true)
    Risk::StrandedBuyerRecoveryService::Result.new(
      verdict:, reason:, attribution: nil, cleared:, skipped:, dry_run:
    )
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "does nothing when the scan finds nobody" do
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [], truncated: false)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "dry-runs every candidate while the flag is off and says so in the report" do
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [candidate], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:cleared, :single_decline_auto_block, cleared: [PlatformBlock.new(object_type: PlatformBlock::TYPES[:email], object_value: candidate[:email])]))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call)
      .with(email: candidate[:email], user_external_id: candidate[:purchaser_external_id], dry_run: true)
    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, sender, message|
      expect(room).to eq("risk")
      expect(sender).to eq("Stranded buyer recovery")
      expect(message).to include("DRY RUN")
      expect(message).to include("would recover 1 of 1")
    end
  end

  it "clears live when auto_recover_stranded_buyers is active" do
    Feature.activate(:auto_recover_stranded_buyers)
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [candidate], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:cleared, :single_decline_auto_block, dry_run: false))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call)
      .with(email: candidate[:email], user_external_id: candidate[:purchaser_external_id], dry_run: false)
    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("Recovered 1 of 1")
      expect(message).not_to include("DRY RUN")
    end
  ensure
    Feature.deactivate(:auto_recover_stranded_buyers)
  end

  it "names escalated buyers in the report so a human sees the authored blocks" do
    escalated = candidate.merge(email: "authored@example.com", purchaser_external_id: nil)
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [escalated], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:escalate, :authored_block))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("ESCALATE authored@example.com")
    end
  end

  it "continues past a candidate whose clear raises, reporting the error" do
    failing = candidate.merge(email: "boom@example.com")
    ok = candidate.merge(email: "fine@example.com")
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [failing, ok], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "boom@example.com"))
      .and_raise(Risk::StrandedBuyerRecoveryService::VerificationFailedError, "block survived clear")
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "fine@example.com"))
      .and_return(recovery_result(:cleared, :single_decline_auto_block))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call).twice
    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("ERROR boom@example.com — Risk::StrandedBuyerRecoveryService::VerificationFailedError: block survived clear")
      expect(message).to include("would recover 1 of 2")
    end
  end

  # The rescue is deliberately StandardError-wide: an uncaught deadlock or RecordInvalid on
  # candidate #3 would otherwise skip the rest of the run AND the report.
  it "survives an error the service did not classify" do
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [candidate], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call).and_raise(ActiveRecord::Deadlocked, "lock wait")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("ERROR stranded@example.com — ActiveRecord::Deadlocked: lock wait")
    end
  end

  it "reports every count from the outcomes, not just the cleared line" do
    outcomes = [
      candidate.merge(email: "cleared@example.com"),
      candidate.merge(email: "skipped@example.com"),
      candidate.merge(email: "noop@example.com"),
    ]
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: outcomes, truncated: false)
    cleared_blocks = [PlatformBlock.new, PlatformBlock.new]
    withheld_blocks = [[PlatformBlock.new, :shared_identifier_needs_human_review]]
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "cleared@example.com"))
      .and_return(recovery_result(:cleared, :single_decline_auto_block, cleared: cleared_blocks, skipped: withheld_blocks))
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "skipped@example.com"))
      .and_return(recovery_result(:skip, :no_clean_payment_history))
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "noop@example.com"))
      .and_return(recovery_result(:noop, :no_active_blocks))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("would recover 1 of 3")
      expect(message).to include("(3 candidates total)")
      expect(message).to include("2 blocks cleared")
      expect(message).to include("1 withheld for a human")
      expect(message).to include("1 skipped")
      expect(message).to include("1 no-ops")
    end
  end

  it "stops starting recoveries once the run budget elapses and reports the remainder as unprocessed" do
    candidates = 3.times.map { |i| candidate.merge(email: "slow#{i}@example.com") }
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: candidates, truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call) do
      travel described_class::RUN_BUDGET + 1.minute
      recovery_result(:skip, :no_clean_payment_history)
    end

    travel_to(Time.current) { described_class.new.perform }

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call).once
    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("2 due today left unprocessed")
    end
  end

  it "bounds one run to at most MAX_RECOVERIES_PER_RUN candidates even when a day's bucket is larger" do
    # A pool many multiples of ROTATION_BUCKETS forces today's bucket above MAX_RECOVERIES_PER_RUN
    # for some day; walk every day of a cycle and check each run's own call count individually.
    many = (described_class::ROTATION_BUCKETS * (described_class::MAX_RECOVERIES_PER_RUN + 3)).times.map do |i|
      candidate.merge(email: "buyer#{i}@example.com")
    end
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: many, truncated: false)

    calls_this_run = 0
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call) do
      calls_this_run += 1
      recovery_result(:skip, :no_clean_payment_history)
    end

    # Three full cycles: an oversized bucket serves a different subpage each cycle, so which day
    # saturates the cap depends on the cycle counter — one cycle alone can miss every subpage.
    per_run_counts = (0...(described_class::ROTATION_BUCKETS * described_class::SUBPAGES_PER_BUCKET * 3)).map do |offset|
      calls_this_run = 0
      travel_to(Date.new(2026, 1, 1) + offset) { described_class.new.perform }
      calls_this_run
    end

    expect(per_run_counts).to all(be <= described_class::MAX_RECOVERIES_PER_RUN)
    # Subpages are hash-based, not exact slices, so no single day is guaranteed to hit the cap
    # exactly — assert the cap binds at all (some day gets close to it), not an exact value.
    expect(per_run_counts.max).to be > described_class::MAX_RECOVERIES_PER_RUN / 2
  end

  # A dry run mutates nothing, so without day-bucketing the same population would be re-evaluated
  # forever. Bucketing by a hash of each buyer's OWN email (not their position in the scan array)
  # means the buyer's day assignment is stable across runs even as the scan's membership/order
  # churns — walk every day of a full cycle and everyone must have been selected exactly once.
  it "processes every candidate exactly once across a full rotation cycle, immune to scan churn between runs" do
    many = (described_class::ROTATION_BUCKETS * 3).times.map { |i| candidate.merge(email: "buyer#{i}@example.com") }
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call).and_return(recovery_result(:skip, :no_clean_payment_history))

    seen = Hash.new(0)
    allow(Risk::StrandedBuyerScanService).to receive(:call) do
      # Simulate churn: reshuffle scan order every run, the exact shape that broke the
      # array-index rotation this replaced.
      { stranded: many.shuffle, truncated: false }
    end
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call) do |email:, **|
      seen[email] += 1
      recovery_result(:skip, :no_clean_payment_history)
    end

    (0...described_class::ROTATION_BUCKETS).each do |offset|
      travel_to(Date.new(2026, 1, 1) + offset) { described_class.new.perform }
    end

    expect(seen.keys).to match_array(many.map { |c| c[:email] })
    expect(seen.values.uniq).to eq([1])
  end

  # Greptile round 9's P1: sub-paging by POSITION (each_slice) shifts every buyer's slice index
  # whenever the bucket's membership changes between occurrences, so a persistently-stranded buyer
  # can drift out of every page that ever gets selected. Splitting by a hash of the buyer's OWN
  # identity fixes that: reaches every candidate in an oversized bucket across successive cycles,
  # AND is immune to the bucket's membership churning between them.
  it "reaches every candidate in an oversized bucket across successive cycles, immune to membership churn" do
    bucket_size = described_class::MAX_RECOVERIES_PER_RUN + 5
    many = bucket_size.times.map { |i| candidate.merge(email: "bucketmate#{i}@example.com") }
    job = described_class.new
    allow(job).to receive(:bucket).and_return(0)

    seen = Hash.new(0)
    described_class::SUBPAGES_PER_BUCKET.times do |cycle|
      travel_to(described_class::ROTATION_EPOCH + (cycle * described_class::ROTATION_BUCKETS)) do
        # Churn: the bucket gains a GROWING set of front-sorted newcomers each cycle (0, 1, 2, 3
        # extra), so each_slice's page boundaries shift by a DIFFERENT amount every occurrence —
        # the shape that lets a position-based page silently skip or double-cover a buyer across
        # cycles. Under the hash-based design a buyer's subpage never depends on who else is due.
        churned = many + cycle.times.map { |n| candidate.merge(email: "aaanewcomer#{cycle}_#{n}@example.com") }
        _bucket_id, page = job.send(:window, churned)
        page.each { |c| seen[c[:email]] += 1 if many.map { _1[:email] }.include?(c[:email]) }
      end
    end

    expect(seen.keys.uniq).to match_array(many.map { |c| c[:email] })
    expect(seen.values).to all(eq(1))
  end

  # Same elapsed-day clock (not `Date.current.yday`, which resets every January) drives both the
  # bucket and subpage cycles — a year boundary must not skip or double-run any subpage.
  it "reaches every subpage of an oversized bucket across a full year, including the January reset" do
    bucket_size = described_class::MAX_RECOVERIES_PER_RUN * 4 # forces multiple subpages
    many = bucket_size.times.map { |i| candidate.merge(email: "bigbucket#{i}@example.com") }
    job = described_class.new
    allow(job).to receive(:bucket).and_return(0)

    seen_subpages = Set.new
    (0...(described_class::ROTATION_BUCKETS * described_class::SUBPAGES_PER_BUCKET * 2)).each do |offset|
      travel_to(described_class::ROTATION_EPOCH + 150 + offset) do
        page_key, = job.send(:window, many)
        seen_subpages << page_key[1] if page_key
      end
    end

    expect(seen_subpages).to eq((0...described_class::SUBPAGES_PER_BUCKET).to_set)
  end

  # Greptile's run-budget-starves-page-suffix P1: an oversized page's composition and order are
  # deterministic per occurrence, so a run that always exhausts RUN_BUDGET on the same early buyer
  # would restart at that same buyer every time this page recurs, never reaching the suffix.
  it "advances the page's starting point across successive occurrences of the same page" do
    bucket_size = described_class::MAX_RECOVERIES_PER_RUN + 5
    many = bucket_size.times.map { |i| candidate.merge(email: "slowbucket#{i.to_s.rjust(2, '0')}@example.com") }
    job = described_class.new
    allow(job).to receive(:bucket).and_return(0)

    _page_key, first_occurrence = travel_to(described_class::ROTATION_EPOCH) { job.send(:window, many) }
    job.send(:save_page_cursor, [0, 0], first_occurrence.first[:email]) # simulate a run that only got through the first buyer
    # Same bucket (0), same subpage cycle: subpage_id is (elapsed_days / ROTATION_BUCKETS) %
    # SUBPAGES_PER_BUCKET, so advancing by ROTATION_BUCKETS * SUBPAGES_PER_BUCKET days returns to
    # the same subpage — the exact occurrence a fixed-order page would replay identically.
    cycle_days = described_class::ROTATION_BUCKETS * described_class::SUBPAGES_PER_BUCKET
    _page_key, second_occurrence = travel_to(described_class::ROTATION_EPOCH + cycle_days) { job.send(:window, many) }

    expect(second_occurrence.first).not_to eq(first_occurrence.first)
  end

  # Greptile's shared-bucket-cursor P1: a cursor keyed on bucket_id alone accumulates identically
  # regardless of which subpage within the bucket ran, so on same-sized subpages `cursor %
  # page.size` returns to 0 whenever the cursor's total equals a multiple of the subpage size —
  # replaying every subpage's own first prefix and stranding its suffix forever.
  it "advances each subpage's own cursor independently, not a cursor shared across the bucket's subpages" do
    many = (described_class::MAX_RECOVERIES_PER_RUN * 4).times.map { |i| candidate.merge(email: "sharedbucket#{i.to_s.rjust(3, '0')}@example.com") }
    job = described_class.new
    allow(job).to receive(:bucket).and_return(0)

    first_prefixes = {}
    described_class::SUBPAGES_PER_BUCKET.times do |cycle|
      travel_to(described_class::ROTATION_EPOCH + (cycle * described_class::ROTATION_BUCKETS)) do
        page_key, page = job.send(:window, many)
        first_prefixes[cycle] = page.first(5)
        job.send(:save_page_cursor, page_key, page.first(5).last[:email]) # each occurrence only got through 5 buyers
      end
    end

    cycle_days = described_class::ROTATION_BUCKETS * described_class::SUBPAGES_PER_BUCKET
    described_class::SUBPAGES_PER_BUCKET.times do |cycle|
      travel_to(described_class::ROTATION_EPOCH + cycle_days + (cycle * described_class::ROTATION_BUCKETS)) do
        _page_key, page = job.send(:window, many)
        expect(page.first(5)).not_to eq(first_prefixes[cycle])
      end
    end
  end

  # nyomanjyotisa's review: the run-budget cursor previously only covered the oversized-bucket
  # sub-paging branch. A normal (<=25) bucket window returned [nil, due_today] and skipped
  # save_page_cursor entirely, so a RUN_BUDGET-truncated run on an ordinary day always restarted
  # at the same email-sorted first buyer — starving everyone after them in that bucket forever.
  it "advances a normal (non-oversized) bucket's starting point across successive occurrences" do
    # Total pool must exceed MAX_RECOVERIES_PER_RUN so `window` takes the bucketing path at all;
    # only the "target" half is due in bucket 0, keeping that bucket itself non-oversized.
    target = (described_class::MAX_RECOVERIES_PER_RUN - 5).times.map { |i| candidate.merge(email: "target#{i.to_s.rjust(2, '0')}@example.com") }
    other = described_class::MAX_RECOVERIES_PER_RUN.times.map { |i| candidate.merge(email: "other#{i.to_s.rjust(2, '0')}@example.com") }
    many = target + other
    job = described_class.new
    allow(job).to receive(:bucket) { |email| email.include?("target") ? 0 : 1 }

    _page_key, first_occurrence = travel_to(described_class::ROTATION_EPOCH) { job.send(:window, many) }
    job.send(:save_page_cursor, [0], first_occurrence.first[:email]) # simulate a run that only got through the first buyer
    # Same bucket (0) recurs every ROTATION_BUCKETS days.
    _page_key, second_occurrence = travel_to(described_class::ROTATION_EPOCH + described_class::ROTATION_BUCKETS) { job.send(:window, many) }

    expect(second_occurrence.first).not_to eq(first_occurrence.first)
  end

  # Same starvation shape when the whole population fits in one run (no bucketing at all): the
  # window is still a deterministic sort every time, so it needs the same persisted cursor.
  it "advances the starting point across successive runs when the whole population fits in one window" do
    many = (described_class::MAX_RECOVERIES_PER_RUN - 5).times.map { |i| candidate.merge(email: "total#{i.to_s.rjust(2, '0')}@example.com") }
    job = described_class.new

    _page_key, first_run = job.send(:window, many)
    job.send(:save_page_cursor, [:total], first_run.first[:email]) # simulate a run that only got through the first buyer

    _page_key, second_run = job.send(:window, many)

    expect(second_run.first).not_to eq(first_run.first)
  end

  # Greptile's capped-page-rotation P1: the cursor previously stored a NUMERIC OFFSET into the
  # current sorted/capped subpage, so alternating peers joining on either side of it (a 50-member
  # subpage capped at 25, cursor bouncing between 0 and 25) could keep one buyer permanently outside
  # the capped prefix even though their bucket/subpage runs every cycle. An EMAIL identity boundary
  # (resume just after this buyer) is immune to how many peers sit on either side of it.
  it "resumes right after the last-processed buyer's identity, not a numeric offset into the page" do
    job = described_class.new
    persistent = candidate.merge(email: "buyer040@example.com")
    page = 60.times.map { |i| candidate.merge(email: "buyer#{i.to_s.rjust(3, '0')}@example.com") }

    job.send(:save_page_cursor, [:test], "buyer039@example.com") # last run stopped right before persistent

    rotated = job.send(:rotate_page, [:test], page)

    expect(rotated.first(25)).to include(a_hash_including(email: persistent[:email]))
  end

  it "is registered on the schedule so it actually runs" do
    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))

    expect(schedule.values.map { |entry| entry["class"] }).to include(described_class.name)
  end

  # Every example above stubs the worker, and InternalNotificationMailer#notify returns silently
  # when the room has no recipient — which would leave the job permanently dark with all specs green.
  it "sends to a room that resolves to a real recipient" do
    mail = InternalNotificationMailer.notify(room_name: "risk", sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end

  # Greptile's hash-subpage-exceeds-run-cap P1: SUBPAGES_PER_BUCKET is sized for the population at
  # write time, but a hash split gives no size guarantee, so a skewed distribution can still put
  # more than MAX_RECOVERIES_PER_RUN buyers in one selected subpage. `perform` must cap the actual
  # candidates it recovers, not just report a documented limit.
  it "caps recoveries at MAX_RECOVERIES_PER_RUN even when a hash subpage is oversized" do
    oversized = (described_class::MAX_RECOVERIES_PER_RUN + 10).times.map { |i| candidate.merge(email: "skewed#{i.to_s.rjust(2, '0')}@example.com") }
    job = described_class.new
    allow(job).to receive(:bucket).and_return(0)
    allow(job).to receive(:subpage).and_return(0)
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: oversized, truncated: false)
    calls = 0
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call) do
      calls += 1
      recovery_result(:skip, :no_clean_payment_history)
    end
    allow(described_class).to receive(:new).and_return(job)

    travel_to(described_class::ROTATION_EPOCH) { job.perform }

    expect(calls).to eq(described_class::MAX_RECOVERIES_PER_RUN)
  end
end
