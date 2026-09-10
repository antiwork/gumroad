# frozen_string_literal: true

require "spec_helper"

describe RepairOrderChargeOutcomesJob do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:product_1) { create(:product, user: seller_1) }
  let(:product_2) { create(:product, user: seller_2) }

  # Models the enqueue being lost: `update_columns` writes the terminal states without firing the
  # `after_commit` that would normally enqueue the reconciliation, so nothing writes the flag. It
  # also sidesteps the charge-path validations, which is not what this job reads.
  def settle_with_lost_enqueue(order)
    succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
    failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << succeeded << failed
    succeeded.update_columns(purchase_state: "successful")
    failed.update_columns(purchase_state: "failed")
    RecordOrderChargeOutcomeJob.jobs.clear
    order
  end

  before do
    $redis.del(
      RedisKey.order_charge_outcome_repair_cursor,
      RedisKey.order_charge_outcome_repair_lap_ceiling,
      RedisKey.order_charge_outcome_repair_recent_mark
    )
  end

  it "flags a partial order whose reconciliation enqueue was lost" do
    order = settle_with_lost_enqueue(create(:order))
    expect(order.reload).not_to be_partially_successful

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  # Absolute ages throughout, not `RECENT_WINDOW.ago` — a fixture derived from the constant moves
  # with it and cannot pin any boundary at all.
  it "flags an order that settled long after checkout, past the freshness window" do
    order = settle_with_lost_enqueue(create(:order))
    order.update_column(:created_at, 30.days.ago)

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  # nyomanjyotisa reproduced this at 120 days: a preorder has no maximum release date, so any
  # old-side horizon permanently excludes whatever settles after it. The walk now has none.
  it "flags an order that settled beyond every settlement horizon" do
    order = settle_with_lost_enqueue(create(:order))
    order.update_column(:created_at, 120.days.ago)

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  it "does not flag an order that is not partial" do
    order = create(:order)
    one = create(:purchase_in_progress, link: product_1, seller: seller_1)
    two = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << one << two
    one.update_columns(purchase_state: "successful")
    two.update_columns(purchase_state: "successful")
    RecordOrderChargeOutcomeJob.jobs.clear

    described_class.new.perform

    expect(order.reload).not_to be_partially_successful
  end

  it "resumes the backlog walk from the saved cursor and wraps once past the end" do
    older = settle_with_lost_enqueue(create(:order))
    newer = settle_with_lost_enqueue(create(:order))
    [older, newer].each { _1.update_column(:created_at, 30.days.ago) }
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)

    described_class.new.perform
    expect(older.reload).to be_partially_successful
    expect(newer.reload).not_to be_partially_successful
    expect($redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i).to eq(older.id)

    described_class.new.perform
    expect(newer.reload).to be_partially_successful

    # Nothing left past the cursor, so the third run wraps rather than stalling there. Both orders
    # are flagged by now and have left the candidate set, so the wrapped page is empty and the
    # cursor stays at the start — which is what makes the next lap see a newly-stranded order.
    described_class.new.perform
    expect($redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i).to eq(0)
  end

  it "reads from the primary" do
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).at_least(:once).and_call_original

    described_class.new.perform
  end

  # Greptile (P1): an order all of whose purchases are already checkout-failed (both hard-declined,
  # no successful sibling ever) can never satisfy `record_charge_outcome!`'s succeeded-and-failed
  # check, so it can never leave the candidate set. A persistent pile of these would resurface every
  # run and crowd out real repairable orders and the whole shared budget.
  it "excludes an order whose purchases are all checkout-failed, since it can never become partial" do
    order = create(:order)
    one = create(:purchase_in_progress, link: product_1, seller: seller_1)
    two = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << one << two
    one.update_columns(purchase_state: "failed")
    two.update_columns(purchase_state: "failed")
    RecordOrderChargeOutcomeJob.jobs.clear
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)

    real = settle_with_lost_enqueue(create(:order))

    described_class.new.perform

    expect(order.reload).not_to be_partially_successful
    expect(real.reload).to be_partially_successful
  end

  # Greptile (P1): the fresh pass had no cap and reconciled every candidate created in the last
  # three days in one invocation — a burst of failures could make this hourly low-priority job
  # perform an unbounded number of primary reads and writes. Both passes now share one budget.
  it "caps the fresh pass at the shared per-run budget rather than reconciling every candidate" do
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)
    first = settle_with_lost_enqueue(create(:order))
    second = settle_with_lost_enqueue(create(:order))

    described_class.new.perform
    expect([first.reload.partially_successful?, second.reload.partially_successful?]).to eq([true, false])

    described_class.new.perform
    expect(second.reload).to be_partially_successful
  end

  # Greptile (P1): the backlog cursor advances before the repair runs, so a process exiting between
  # `save_cursor` and the actual write can leave a low-id order permanently below the cursor — the
  # wrap that would revisit it only fires once a page comes back empty, which never happens while
  # newer old-side failures keep arriving above the cursor. Fixing this needs the lap's upper bound
  # pinned at lap start: once the cursor passes THAT ceiling the page is empty regardless of what
  # arrived after, so the wrap (and the revisit) is guaranteed rather than starvable.
  it "still repairs a stale order left below the cursor, even as new old-side failures keep arriving above it" do
    stale = settle_with_lost_enqueue(create(:order))
    stale.update_column(:created_at, 30.days.ago)
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)

    # Mirrors the crash Greptile reproduced: the cursor and lap ceiling already advanced past
    # `stale`, but its repair itself never landed.
    $redis.set(RedisKey.order_charge_outcome_repair_cursor, stale.id)
    $redis.set(RedisKey.order_charge_outcome_repair_lap_ceiling, stale.id)
    expect(stale.reload).not_to be_partially_successful

    newer = settle_with_lost_enqueue(create(:order))
    newer.update_column(:created_at, 30.days.ago)

    described_class.new.perform

    expect(stale.reload).to be_partially_successful
  end

  it "wraps candidate lookups in WithMaxExecutionTime" do
    expect(WithMaxExecutionTime).to receive(:timeout_queries)
      .with(seconds: described_class::QUERY_TIME_BUDGET)
      .and_call_original

    described_class.new.perform
  end

  it "keeps each purchase id lookup at or under the IN-list batch size" do
    expect(described_class::FAILED_ORDER_ID_BATCH).to be <= 1_000
    expect(described_class::FAILED_ORDER_ID_BATCH).to be < described_class::MAX_BACKLOG_SCANNED
  end

  it "does not emit the old DISTINCT double-join of failed and non-failed purchases" do
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sqls << payload[:sql]
    end
    settle_with_lost_enqueue(create(:order))
    described_class.new.perform
    ActiveSupport::Notifications.unsubscribe(subscriber)

    purchase_sqls = sqls.select { _1.include?("purchase_state") }
    expect(purchase_sqls).not_to be_empty
    combined = purchase_sqls.select { |sql| sql.include?("`purchase_state` IN (") && sql.include?("NOT IN (") }
    expect(combined).to be_empty
  end

  # An unindexed updated_at scan would abort the 2-minute cap. A new order
  # whose failed purchase predates RECENT_WINDOW is repaired once the order
  # itself is old enough for the backlog pass.
  it "repairs via backlog an old order whose failed purchase predates the freshness window" do
    order = create(:order)
    succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
    failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << succeeded << failed
    succeeded.update_columns(purchase_state: "successful")
    failed.update_columns(purchase_state: "failed", created_at: 30.days.ago, updated_at: Time.current)
    order.update_column(:created_at, 4.days.ago)
    RecordOrderChargeOutcomeJob.jobs.clear

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  # Greptile (P1): a full failed-order scan budget of non-qualifying rows used to
  # discard the scan cursor, so the next hour rescanned the same stretch.
  it "advances the backlog cursor across a sparse stretch of non-qualifying failed orders" do
    stub_const("#{described_class}::MAX_FAILED_ORDER_BATCHES", 1)
    stub_const("#{described_class}::FAILED_ORDER_ID_BATCH", 1)
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)

    blocker = create(:order)
    one = create(:purchase_in_progress, link: product_1, seller: seller_1)
    two = create(:purchase_in_progress, link: product_2, seller: seller_2)
    blocker.purchases << one << two
    one.update_columns(purchase_state: "failed")
    two.update_columns(purchase_state: "failed")
    blocker.update_column(:created_at, 30.days.ago)
    RecordOrderChargeOutcomeJob.jobs.clear

    real = settle_with_lost_enqueue(create(:order))
    real.update_column(:created_at, 30.days.ago)

    described_class.new.perform
    expect(blocker.reload).not_to be_partially_successful
    expect(real.reload).not_to be_partially_successful
    expect($redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i).to eq(blocker.id)

    described_class.new.perform
    expect(real.reload).to be_partially_successful
  end

  # One qualifying row used to pin the cursor at ids.last, so the rest of a
  # fully-filtered 40-page window was walked again next hour.
  it "advances the backlog cursor to the last scanned failed order when a candidate sits in an otherwise sparse window" do
    stub_const("#{described_class}::MAX_FAILED_ORDER_BATCHES", 2)
    stub_const("#{described_class}::FAILED_ORDER_ID_BATCH", 1)
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 10)

    real = settle_with_lost_enqueue(create(:order))
    real.update_column(:created_at, 30.days.ago)

    blocker = create(:order)
    one = create(:purchase_in_progress, link: product_1, seller: seller_1)
    two = create(:purchase_in_progress, link: product_2, seller: seller_2)
    blocker.purchases << one << two
    one.update_columns(purchase_state: "failed")
    two.update_columns(purchase_state: "failed")
    blocker.update_column(:created_at, 30.days.ago)
    RecordOrderChargeOutcomeJob.jobs.clear

    described_class.new.perform
    expect(real.reload).to be_partially_successful
    expect(blocker.reload).not_to be_partially_successful
    expect($redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i).to eq(blocker.id)
  end

  # Fully-failed recent purchases never grow the candidate cap, so without a
  # page bound the recent pass can consume the whole run before backlog.
  it "stops the recent failed-purchase scan at the failed-order batch cap" do
    stub_const("#{described_class}::MAX_FAILED_ORDER_BATCHES", 1)
    stub_const("#{described_class}::FAILED_ORDER_ID_BATCH", 1)

    3.times do
      order = create(:order)
      one = create(:purchase_in_progress, link: product_1, seller: seller_1)
      two = create(:purchase_in_progress, link: product_2, seller: seller_2)
      order.purchases << one << two
      one.update_columns(purchase_state: "failed")
      two.update_columns(purchase_state: "failed")
      RecordOrderChargeOutcomeJob.jobs.clear
    end

    job = described_class.new
    calls = 0
    allow(job).to receive(:order_ids_for_purchases).and_wrap_original do |method, *args|
      calls += 1
      method.call(*args)
    end

    job.perform

    expect(calls).to eq(1)
  end

  # A page that yields more candidates than the remaining budget must leave the
  # high-water mark before the overflow purchases, otherwise those orders are
  # skipped until a wrap that ongoing fresh failures can starve.
  it "does not advance the recent mark past overflow candidates when the budget fills mid-page" do
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)
    stub_const("#{described_class}::FAILED_ORDER_ID_BATCH", 10)
    stub_const("#{described_class}::MAX_FAILED_ORDER_BATCHES", 1)

    first = settle_with_lost_enqueue(create(:order))
    second = settle_with_lost_enqueue(create(:order))
    mark = first.purchases.minimum(:id) - 1
    $redis.set(RedisKey.order_charge_outcome_repair_recent_mark, mark)

    described_class.new.perform

    expect(first.reload).to be_partially_successful
    expect(second.reload).not_to be_partially_successful
    saved = $redis.get(RedisKey.order_charge_outcome_repair_recent_mark).to_i
    expect(saved).to be < second.purchases.minimum(:id)
    expect(saved).to be >= first.purchases.maximum(:id)

    described_class.new.perform
    expect(second.reload).to be_partially_successful
  end

  # Oldest-first in_batches under a full page budget never reaches the head of
  # the window. With the recent-pass high-water already past the older failures,
  # one run still repairs the newest stranded order.
  it "repairs the newest stranded recent order when older failed purchases exceed the page budget" do
    stub_const("#{described_class}::MAX_FAILED_ORDER_BATCHES", 1)
    stub_const("#{described_class}::FAILED_ORDER_ID_BATCH", 1)

    3.times do
      order = create(:order)
      one = create(:purchase_in_progress, link: product_1, seller: seller_1)
      two = create(:purchase_in_progress, link: product_2, seller: seller_2)
      order.purchases << one << two
      one.update_columns(purchase_state: "failed")
      two.update_columns(purchase_state: "failed")
      RecordOrderChargeOutcomeJob.jobs.clear
    end

    newest = settle_with_lost_enqueue(create(:order))
    mark = newest.purchases.minimum(:id) - 1
    $redis.set(RedisKey.order_charge_outcome_repair_recent_mark, mark)

    described_class.new.perform

    expect(newest.reload).to be_partially_successful
  end

  # A lost lap-ceiling key mid-lap used to leave the page unbounded above, so
  # new failed rows kept every page non-empty and the wrap never fired.
  it "recomputes a missing lap ceiling mid-lap so the backlog walk can still wrap" do
    older = settle_with_lost_enqueue(create(:order))
    newer = settle_with_lost_enqueue(create(:order))
    [older, newer].each { _1.update_column(:created_at, 30.days.ago) }
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)

    $redis.set(RedisKey.order_charge_outcome_repair_cursor, older.id)
    $redis.del(RedisKey.order_charge_outcome_repair_lap_ceiling)

    described_class.new.perform

    expect(newer.reload).to be_partially_successful
    expect($redis.get(RedisKey.order_charge_outcome_repair_lap_ceiling).to_i).to be >= newer.id
  end
end
