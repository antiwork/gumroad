# frozen_string_literal: true

require "spec_helper"

describe Onetime::SyncPlatformBlocksFromMongo do
  before { PlatformBlock.delete_all }

  def silence_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe ".process" do
    it "copies active records from Mongo to MySQL preserving all fields" do
      blocked_at = 2.hours.ago
      expires_at = 1.hour.from_now
      mongo_record = BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: "blocked@example.com",
        blocked_at:,
        expires_at:,
        blocked_by: 42
      )

      silence_stdout { described_class.process }

      row = PlatformBlock.find_by!(object_type: BLOCKED_OBJECT_TYPES[:email], object_value: "blocked@example.com")
      expect(row.blocked_at).to be_within(1.second).of(blocked_at)
      expect(row.expires_at).to be_within(1.second).of(expires_at)
      expect(row.blocked_by).to eq(42)
      expect(row.created_at).to be_within(1.second).of(mongo_record.created_at)
      expect(row.updated_at).to be_within(1.second).of(mongo_record.updated_at)
    end

    it "imports records whose expires_at is in the past (history)" do
      BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: "expired@example.com",
        blocked_at: 2.days.ago,
        expires_at: 1.day.ago,
        blocked_by: nil
      )
      BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: "active@example.com",
        blocked_at: 2.hours.ago,
        expires_at: 1.hour.from_now,
        blocked_by: nil
      )

      silence_stdout { described_class.process }

      expect(PlatformBlock.pluck(:object_value)).to contain_exactly("expired@example.com", "active@example.com")
    end

    it "imports records with no expires_at (permanent blocks)" do
      BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email_domain],
        object_value: "example.org",
        blocked_at: 1.day.ago,
        expires_at: nil,
        blocked_by: nil
      )

      silence_stdout { described_class.process }

      row = PlatformBlock.find_by!(object_value: "example.org")
      expect(row.expires_at).to be_nil
    end

    it "imports unblocked tombstones (blocked_at nil and expires_at nil)" do
      blocked = BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: "tombstone@example.com",
        blocked_at: 2.hours.ago,
        expires_at: nil,
        blocked_by: nil
      )
      blocked.unblock!

      silence_stdout { described_class.process }

      row = PlatformBlock.find_by!(object_value: "tombstone@example.com")
      expect(row.blocked_at).to be_nil
      expect(row.expires_at).to be_nil
    end

    it "returns the last updated_at watermark from the run" do
      mongo_record = BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: "watermark@example.com",
        blocked_at: 1.hour.ago,
        expires_at: nil
      )

      watermark = silence_stdout { described_class.process }

      expect(watermark).to be_within(1.second).of(mongo_record.updated_at)
    end

    it "returns nil watermark when nothing was synced" do
      expect(silence_stdout { described_class.process }).to be_nil
    end

    context "when re-run" do
      it "is idempotent — re-running produces the same MySQL state" do
        BlockedObject.create!(
          object_type: BLOCKED_OBJECT_TYPES[:email],
          object_value: "idempotent@example.com",
          blocked_at: 1.hour.ago,
          expires_at: nil
        )

        silence_stdout { described_class.process }
        silence_stdout { described_class.process }

        expect(PlatformBlock.where(object_value: "idempotent@example.com").count).to eq(1)
      end

      it "does not overwrite created_at on existing rows" do
        BlockedObject.create!(
          object_type: BLOCKED_OBJECT_TYPES[:email],
          object_value: "preserve-created@example.com",
          blocked_at: 1.hour.ago,
          expires_at: nil
        )

        silence_stdout { described_class.process }
        original_created_at = PlatformBlock.find_by!(object_value: "preserve-created@example.com").created_at

        silence_stdout { described_class.process }
        expect(PlatformBlock.find_by!(object_value: "preserve-created@example.com").created_at)
          .to eq(original_created_at)
      end

      it "propagates updates to blocked_at, expires_at and blocked_by" do
        mongo_record = BlockedObject.create!(
          object_type: BLOCKED_OBJECT_TYPES[:email],
          object_value: "mutating@example.com",
          blocked_at: 2.hours.ago,
          expires_at: 1.hour.from_now,
          blocked_by: 1
        )

        silence_stdout { described_class.process }

        mongo_record.update!(blocked_by: 99, expires_at: 2.hours.from_now)

        silence_stdout { described_class.process }

        row = PlatformBlock.find_by!(object_value: "mutating@example.com")
        expect(row.blocked_by).to eq(99)
        expect(row.expires_at).to be_within(1.second).of(2.hours.from_now)
      end

      it "propagates Mongo unblock! (nulls blocked_at and expires_at)" do
        mongo_record = BlockedObject.create!(
          object_type: BLOCKED_OBJECT_TYPES[:email],
          object_value: "to-unblock@example.com",
          blocked_at: 1.hour.ago,
          expires_at: 1.hour.from_now
        )

        silence_stdout { described_class.process }
        mongo_record.unblock!

        silence_stdout { described_class.process }

        row = PlatformBlock.find_by!(object_value: "to-unblock@example.com")
        expect(row.blocked_at).to be_nil
        expect(row.expires_at).to be_nil
      end
    end

    context "with a since: watermark" do
      it "syncs only records updated at or after the watermark" do
        travel_to 3.hours.ago do
          BlockedObject.create!(
            object_type: BLOCKED_OBJECT_TYPES[:email],
            object_value: "older@example.com",
            blocked_at: Time.current,
            expires_at: nil
          )
        end
        travel_to 1.hour.ago do
          BlockedObject.create!(
            object_type: BLOCKED_OBJECT_TYPES[:email],
            object_value: "newer@example.com",
            blocked_at: Time.current,
            expires_at: nil
          )
        end

        silence_stdout { described_class.process(since: 2.hours.ago) }

        expect(PlatformBlock.pluck(:object_value)).to contain_exactly("newer@example.com")
      end

      it "re-syncs the boundary record (>= semantics, not >)" do
        boundary = BlockedObject.create!(
          object_type: BLOCKED_OBJECT_TYPES[:email],
          object_value: "boundary@example.com",
          blocked_at: 1.hour.ago,
          expires_at: nil
        )

        # Resuming with `since:` equal to the watermark must re-include the
        # boundary record; otherwise a mid-batch crash would silently skip rows
        # sharing the same microsecond updated_at.
        silence_stdout { described_class.process(since: boundary.updated_at) }

        expect(PlatformBlock.find_by(object_value: "boundary@example.com")).to be_present
      end
    end

    it "respects batch_size and processes everything across multiple batches" do
      5.times do |i|
        BlockedObject.create!(
          object_type: BLOCKED_OBJECT_TYPES[:email],
          object_value: "batched-#{i}@example.com",
          blocked_at: 1.hour.ago,
          expires_at: nil
        )
      end

      output = capture_stdout { described_class.process(batch_size: 2) }

      expect(PlatformBlock.where("object_value LIKE 'batched-%'").count).to eq(5)
      # 3 batches of size 2, 2, 1 → cumulative log lines printed
      expect(output.scan(/PlatformBlock sync:/).size).to eq(3)
    end
  end
end
