# frozen_string_literal: true

require "spec_helper"

describe EmailInfo do
  let(:buffer_key) { RedisKey.email_info_delivered_buffer }

  describe ".buffer_delivered" do
    it "pushes a record and enqueues the flush job without touching MySQL" do
      email_info = create(:creator_contacting_customers_email_info_sent)
      delivered_at = 1.hour.ago

      result = EmailInfo.buffer_delivered(installment_id: email_info.installment_id, purchase_id: email_info.purchase_id, delivered_at:)

      expect(result).to eq(true)
      expect($redis.lrange(buffer_key, 0, -1)).to eq([{ i: email_info.installment_id, p: email_info.purchase_id, t: delivered_at.to_i }.to_json])
      expect(FlushDeliveredEmailInfosJob).to have_enqueued_sidekiq_job
      expect(email_info.reload.state).to eq("sent")
      expect(email_info.delivered_at).to be_nil
    end

    it "returns false when Redis rejects the push" do
      allow($redis).to receive(:rpush).and_raise(Redis::CannotConnectError)

      result = EmailInfo.buffer_delivered(installment_id: 1, purchase_id: 2, delivered_at: Time.current)

      expect(result).to eq(false)
      expect(FlushDeliveredEmailInfosJob).not_to have_enqueued_sidekiq_job
    end
  end

  describe ".flush_delivered_buffer!" do
    let(:installment_a) { create(:installment) }
    let(:installment_b) { create(:installment) }
    let(:delivered_at) { 2.hours.ago.change(usec: 0) }

    def buffer(email_info, at = delivered_at)
      $redis.rpush(buffer_key, { i: email_info.installment_id, p: email_info.purchase_id, t: at.to_i }.to_json)
    end

    it "marks created and sent rows delivered with the event timestamp, grouped by installment" do
      a1 = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      a2 = create(:creator_contacting_customers_email_info, installment: installment_a)
      b1 = create(:creator_contacting_customers_email_info_sent, installment: installment_b)
      untouched = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      buffer(a1)
      buffer(a2, delivered_at + 5.minutes)
      buffer(b1, delivered_at + 10.minutes)

      expect(CreatorContactingCustomersEmailInfo).to receive(:where).twice.and_call_original
      EmailInfo.flush_delivered_buffer!

      expect(a1.reload).to have_attributes(state: "delivered", delivered_at:)
      expect(a2.reload).to have_attributes(state: "delivered", delivered_at: delivered_at + 5.minutes)
      expect(b1.reload).to have_attributes(state: "delivered", delivered_at: delivered_at + 10.minutes)
      expect(untouched.reload).to have_attributes(state: "sent", delivered_at: nil)
      expect($redis.llen(buffer_key)).to eq(0)
    end

    it "does not downgrade an opened row" do
      opened = create(:creator_contacting_customers_email_info_opened, installment: installment_a)
      buffer(opened)

      EmailInfo.flush_delivered_buffer!

      expect(opened.reload.state).to eq("opened")
      expect(opened.opened_at).to be_present
    end

    it "keeps the original delivered_at of an already-delivered row" do
      original = 1.day.ago.change(usec: 0)
      delivered = create(:creator_contacting_customers_email_info_delivered, installment: installment_a, delivered_at: original)
      buffer(delivered)

      EmailInfo.flush_delivered_buffer!

      expect(delivered.reload).to have_attributes(state: "delivered", delivered_at: original)
    end

    it "does not create a row for a purchase with no send record" do
      $redis.rpush(buffer_key, { i: installment_a.id, p: 123_456_789, t: delivered_at.to_i }.to_json)

      expect { EmailInfo.flush_delivered_buffer! }.not_to change { CreatorContactingCustomersEmailInfo.count }
    end

    it "keeps the chunk in the inflight list and re-raises when the UPDATE fails" do
      email_info = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      buffer(email_info)
      allow(CreatorContactingCustomersEmailInfo).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { EmailInfo.flush_delivered_buffer! }.to raise_error(ActiveRecord::StatementInvalid)

      expect($redis.llen(buffer_key)).to eq(0)
      expect($redis.llen(RedisKey.email_info_delivered_inflight)).to eq(1)
      expect(email_info.reload.state).to eq("sent")
    end

    it "applies a leftover inflight chunk before taking more from the buffer" do
      leftover = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      later = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      $redis.rpush(RedisKey.email_info_delivered_inflight, { i: leftover.installment_id, p: leftover.purchase_id, t: delivered_at.to_i }.to_json)
      buffer(later)

      EmailInfo.flush_delivered_buffer!

      expect(leftover.reload).to have_attributes(state: "delivered", delivered_at:)
      expect(later.reload.state).to eq("delivered")
      expect($redis.llen(RedisKey.email_info_delivered_inflight)).to eq(0)
    end

    it "is a no-op on an empty buffer" do
      expect { EmailInfo.flush_delivered_buffer! }.not_to raise_error
    end

    it "does not delete inflight after losing the flush lock" do
      email_info = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      buffer(email_info)
      allow(EmailInfo).to receive(:apply_delivered_chunk!).and_wrap_original do |original, *args, &blk|
        $redis.set(RedisKey.email_info_delivered_flush_lock, "stolen", ex: 60)
        original.call(*args, &blk)
      end

      EmailInfo.flush_delivered_buffer!

      expect($redis.llen(RedisKey.email_info_delivered_inflight)).to eq(1)
    ensure
      $redis.del(RedisKey.email_info_delivered_flush_lock, RedisKey.email_info_delivered_inflight)
    end

    it "leaves the buffer untouched when another flush holds the lock" do
      email_info = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      buffer(email_info)
      $redis.set(RedisKey.email_info_delivered_flush_lock, "held", nx: true, ex: 60)

      EmailInfo.flush_delivered_buffer!

      expect($redis.llen(buffer_key)).to eq(1)
      expect(email_info.reload.state).to eq("sent")
    ensure
      $redis.del(RedisKey.email_info_delivered_flush_lock)
    end

    it "stops after MAX_FLUSH_CHUNKS and leaves the rest for the next run" do
      stub_const("EmailInfo::DELIVERED_BUFFER_CHUNK", 1)
      stub_const("EmailInfo::MAX_FLUSH_CHUNKS", 1)
      first = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      second = create(:creator_contacting_customers_email_info_sent, installment: installment_a)
      buffer(first)
      buffer(second)

      EmailInfo.flush_delivered_buffer!

      expect(first.reload.state).to eq("delivered")
      expect(second.reload.state).to eq("sent")
      expect($redis.llen(buffer_key)).to eq(1)

      EmailInfo.flush_delivered_buffer!

      expect(second.reload.state).to eq("delivered")
      expect($redis.llen(buffer_key)).to eq(0)
    end
  end
end
