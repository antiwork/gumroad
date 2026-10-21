# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe Onetime::BackfillLegacyFeatureAnnouncementPreferences do
  self.use_transactional_tests = false

  before do
    @users = []
    allow(ReplicaLagWatcher).to receive(:watch)
  end

  after do
    FeatureAnnouncementSubscription.where(user_id: @users.map(&:id)).delete_all
    @users.each(&:destroy!)
    delete_leftovers(user_ids: @users.map(&:id))
  end

  def account(enabled: true)
    create(:user, announcement_notification_enabled: enabled).tap { @users << _1 }
  end

  def process(users = @users, **options)
    described_class.process(upper_user_id: users.last.id, after_user_id: users.first.id - 1, **options)
  end

  def preference(user) = FeatureAnnouncementSubscription.find_by(user_id: user.id)

  it "defaults to a dry run without writes or row locks" do
    enabled = account
    disabled = account(enabled: false)
    statements = []
    observer = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| statements << event.payload[:sql] }

    report = process

    expect(report).to include(dry_run: true, scanned: 2, candidates: 1, legacy_off: 1, inserted: 0, cursor: disabled.id, exhausted: true)
    expect(FeatureAnnouncementSubscription.where(user_id: @users.map(&:id))).to be_empty
    expect(statements.grep(/\b(?:INSERT|UPDATE|DELETE|BEGIN|COMMIT|FOR UPDATE|FOR SHARE)\b/i)).to be_empty
    expect(ReplicaLagWatcher).not_to have_received(:watch)
    expect(enabled.reload.announcement_notification_enabled).to be(true)
  ensure
    ActiveSupport::Notifications.unsubscribe(observer) if observer
  end

  it "copies the legacy flag without a newsletter follow or an email identity check" do
    enabled = account
    disabled = account(enabled: false)
    enabled.update_columns(confirmed_at: nil, unconfirmed_email: "pending@example.com")
    before_flags = @users.to_h { [_1.id, _1.reload.flags] }

    expect(process(dry_run: false)).to include(scanned: 2, candidates: 1, legacy_off: 1, attempted: 1,
                                               inserted: nil, inserted_count_known: false, observed_source_rows: 1, exhausted: true)
    expect(preference(enabled)).to have_attributes(subscribed: true, source: "legacy_announcements_migration", version: 1)
    expect(preference(disabled)).to be_nil
    expect(@users.to_h { [_1.id, _1.reload.flags] }).to eq(before_flags)
  end

  it "preserves every existing preference and its version, provenance and timestamps" do
    FeatureAnnouncementSubscription::SOURCES.each_with_index do |source, index|
      user = account(enabled: index.even?)
      FeatureAnnouncementSubscription.create!(user_id: user.id, subscribed: index.odd?, source:, version: index + 1)
    end
    before = FeatureAnnouncementSubscription.where(user_id: @users.map(&:id)).map(&:attributes)

    expect(process(dry_run: false)).to include(preserved: @users.size, candidates: 0, attempted: 0)
    expect(FeatureAnnouncementSubscription.where(user_id: @users.map(&:id)).map(&:attributes)).to eq(before)
    expect(process).to include(preserved: @users.size, candidates: 0, inserted: 0)
  end

  it "replays completed pages without changing copied preferences" do
    user = account
    expect(process(dry_run: false)[:attempted]).to eq(1)
    before = preference(user).attributes

    expect(process(dry_run: false)).to include(scanned: 1, preserved: 1, attempted: 0)
    expect(preference(user).attributes).to eq(before)
  end

  it "bounds raw primary-key pages before filtering sparse enabled flags" do
    first = account(enabled: false)
    middle = account(enabled: false)
    last = account
    statements = []
    observer = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| statements << event.payload[:sql] }

    report = process(batch_size: 2, max_batches: 1, dry_run: false)

    expect(report).to include(scanned: 2, legacy_off: 2, attempted: 0, cursor: middle.id, exhausted: false, batches: 1)
    expect(statements.grep(/SELECT .*`users`.*LIMIT 2/).first).to include("ORDER BY `users`.`id` ASC")
    expect(preference(last)).to be_nil
    resumed = described_class.process(upper_user_id: last.id, after_user_id: report[:cursor], dry_run: false)
    expect(resumed).to include(scanned: 1, attempted: 1, cursor: last.id, exhausted: true)
    expect(preference(first)).to be_nil
  ensure
    ActiveSupport::Notifications.unsubscribe(observer) if observer
  end

  it "does not cross the fixed fence or read further when its cursor reaches the fence" do
    first = account
    later = account
    report = process([first], dry_run: false)
    expect(report).to include(scanned: 1, cursor: first.id, exhausted: true)
    expect(preference(later)).to be_nil
    expect(described_class.process(upper_user_id: first.id, after_user_id: first.id, dry_run: false))
      .to include(scanned: 0, attempted: 0, exhausted: true, batches: 0)
  end

  it "stops at the runtime checkpoint and resumes after a committed batch" do
    first = account
    last = account
    now = 0
    allow_any_instance_of(described_class).to receive(:monotonic_time) { now }
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_wrap_original do |original, *arguments|
      original.call(*arguments).tap { now = 10 }
    end

    report = process(batch_size: 1, max_batches: 2, max_run_seconds: 1, dry_run: false)
    expect(report).to include(scanned: 1, attempted: 1, cursor: first.id, exhausted: false)
    expect(preference(last)).to be_nil

    expect(described_class.process(upper_user_id: last.id, after_user_id: report[:cursor], dry_run: false))
      .to include(scanned: 1, attempted: 1, cursor: last.id, exhausted: true)
  end

  it "rechecks a legacy flag changed after the raw page read" do
    user = account
    allow_any_instance_of(ActiveRecord::Relation).to receive(:lock).and_wrap_original do |original, *arguments|
      user.update_columns(flags: user.flags & ~User.flag_mapping["flags"][:announcement_notification_enabled]) if original.receiver.model == User
      original.call(*arguments)
    end

    expect(process(dry_run: false)).to include(legacy_off: 1, attempted: 0)
    expect(preference(user)).to be_nil
  end

  it "serializes the flag check and insert before a concurrent legacy setting change" do
    user = account
    writer = nil
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_wrap_original do |original, *arguments|
      writer = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          User.where(id: user.id).update_all(flags: user.flags & ~User.flag_mapping["flags"][:announcement_notification_enabled])
        end
      end
      Timeout.timeout(5) do
        sleep 0.1 until ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_state = 'LOCK WAIT'").to_i > 0
      end
      original.call(*arguments)
    end

    expect(process(dry_run: false)).to include(attempted: 1)
    writer.value
    expect(user.reload.announcement_notification_enabled).to be(false)
    expect(preference(user)).to have_attributes(subscribed: true, source: described_class::SOURCE)
  ensure
    writer&.join(5)
  end

  [true, false].each do |subscribed|
    it "preserves a concurrent Settings insert with subscribed #{subscribed}" do
      user = account
      allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_wrap_original do |original, *arguments|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            FeatureAnnouncementSubscription.create!(user_id: user.id, subscribed:, source: "settings", version: 3)
          end
        end.value
        original.call(*arguments)
      end

      expect(process(dry_run: false)).to include(scanned: 1, candidates: 1, attempted: 1, observed_source_rows: 0, inserted: nil)
      expect(preference(user)).to have_attributes(subscribed:, source: "settings", version: 3)
    end
  end

  it "preserves an unsubscribe that inserts after the missing-preference check" do
    user = account
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_wrap_original do |original, *arguments|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          FeatureAnnouncementSubscription.unsubscribe!(user, source: "unsubscribe_link")
        end
      end.value
      original.call(*arguments)
    end

    expect(process(dry_run: false)).to include(attempted: 1, observed_source_rows: 0, inserted: nil)
    expect(preference(user)).to have_attributes(subscribed: false, source: "unsubscribe_link", version: 1)
  end

  it "stops on a failed insert and safely replays earlier committed rows" do
    first = account
    last = account
    attempts = 0
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_wrap_original do |original, *arguments|
      attempts += 1
      raise ActiveRecord::LockWaitTimeout, "synthetic lock timeout" if arguments.first.any? { _1[:user_id] == last.id }
      original.call(*arguments)
    end

    expect { process(batch_size: 1, max_batches: 2, dry_run: false) }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(attempts).to eq(2)
    expect(preference(first)).to be_present
    expect(preference(last)).to be_nil
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_call_original
    expect(process(dry_run: false)).to include(scanned: 2, preserved: 1, attempted: 1)
  end

  it "rolls back the whole page when an error follows the bulk insert" do
    account
    account
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_wrap_original do |original, *arguments|
      original.call(*arguments)
      raise ActiveRecord::LockWaitTimeout, "synthetic error before commit"
    end

    expect { process(dry_run: false) }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(FeatureAnnouncementSubscription.where(user_id: @users.map(&:id))).to be_empty
    allow(FeatureAnnouncementSubscription).to receive(:insert_all).and_call_original
    expect(process(dry_run: false)).to include(scanned: 2, attempted: 2)
  end

  it "processes a full raw page with one locked user read and one bulk insert" do
    emails = Array.new(1_000) { |index| "backfill-batch-#{index}@example.com" }
    User.insert_all!(emails.map do |email|
      { email:, flags: User.flag_mapping["flags"][:announcement_notification_enabled], recommendation_type: User::RecommendationType::OWN_PRODUCTS }
    end)
    @users.concat(User.where(email: emails).order(:id).to_a)
    statements = []
    observer = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| statements << event.payload[:sql] }

    expect(process(dry_run: false)).to include(scanned: 1_000, attempted: 1_000, observed_source_rows: 1_000, batches: 1, exhausted: true)
    expect(statements.grep(/SELECT .*FROM `users`.*FOR SHARE/).size).to eq(1)
    expect(statements.grep(/INSERT INTO `feature_announcement_subscriptions`/).size).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(observer) if observer
  end

  it "refuses apply within an ambient transaction" do
    account
    ApplicationRecord.transaction do
      expect { process(dry_run: false) }.to raise_error(ArgumentError, /ambient transaction/)
    end
    expect(FeatureAnnouncementSubscription.where(user_id: @users.map(&:id))).to be_empty
  end

  {
    upper_user_id: [nil, 0, -1, 1.5, "1", 2**63],
    after_user_id: [-1, "0", 1.5, 2**63],
    batch_size: [0, -1, 1_001, 1.5, "1"],
    max_batches: [0, -1, 101, 1.5, "1"],
    max_run_seconds: [0, -1, 91, Float::INFINITY, Float::NAN, Complex(1, 1), "1", nil],
    dry_run: [nil, "false", 0]
  }.each do |field, invalid_values|
    it "rejects invalid #{field} before database access" do
      expect(ApplicationRecord).not_to receive(:connected_to)
      invalid_values.each do |value|
        expect { described_class.process(upper_user_id: 10, field => value) }.to raise_error(ArgumentError)
      end
    end
  end

  it "accepts a finite positive fractional runtime budget" do
    user = account
    expect(process(max_run_seconds: Rational(1, 2))).to include(scanned: 1, candidates: 1, cursor: user.id)
  end
end
