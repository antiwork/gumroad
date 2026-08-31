# frozen_string_literal: true

require "spec_helper"

describe SendPostBlastEmailsSliceJob, :freeze_time do
  include ActionView::Helpers::SanitizeHelper

  before do
    @seller = create(:named_user)
  end

  let(:post_with_audience) do
    post = create(:audience_post, :published, seller: @seller)
    create(:active_follower, user: @seller, email: "alpha@example.com")
    create(:active_follower, user: @seller, email: "bravo@example.com")
    create(:active_follower, user: @seller, email: "charlie@example.com")
    post
  end

  def audience_ids
    AudienceMember.where(seller_id: @seller).pluck(:id)
  end

  let(:partition_key) { "partition-v1" }

  def expect_sent_count(count)
    expect(PostSendgridApi.mails.size).to eq(count)
  end

  describe "#perform" do
    it "sends only the handed chunk and records it as done" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      chunk_ids = audience_ids

      described_class.new.perform(blast.id, partition_key, 0, 1, chunk_ids)

      expect_sent_count 3
      expect(PostSendgridApi.mails.keys).to contain_exactly("alpha@example.com", "bravo@example.com", "charlie@example.com")
      expect(blast.reload.completed_at).to be_present
      # Done-slices set is cleared by the completion stamp.
      expect($redis.exists?(RedisKey.blast_done_slices(blast.id, partition_key))).to eq(false)
    end

    it "decrements the pending recipient count the parent published" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      pending_key = RedisKey.blast_pending_recipients(blast.id)
      $redis.set(pending_key, 3)

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect($redis.get(pending_key).to_i).to eq(0)
    ensure
      $redis.del(pending_key)
    end

    it "stamps completed_at only when the last distinct chunk finishes, even out of order" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      done_key = RedisKey.blast_done_slices(blast.id, partition_key)
      # Chunk 1 of 2 already delivered; its SADD is in the set and the blast is still pending.
      $redis.sadd(done_key, 1)

      described_class.new.perform(blast.id, partition_key, 0, 2, audience_ids.first(1))

      # The final distinct chunk raised the done-slices set to the full count, so the blast
      # completed — and the completion stamp in mark_blast_as_completed clears the set (the
      # same cleanup :29 asserts via its absence check), so its contents are gone afterwards.
      expect(blast.reload.completed_at).to be_present
      expect($redis.exists?(done_key)).to eq(false)
    ensure
      $redis.del(done_key)
    end

    it "keeps stale completion markers from an earlier partition from completing a retry" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      old_partition_key = "old-partition"
      old_done_key = RedisKey.blast_done_slices(blast.id, old_partition_key)
      new_done_key = RedisKey.blast_done_slices(blast.id, partition_key)
      $redis.sadd(old_done_key, [0, 1])

      described_class.new.perform(blast.id, partition_key, 0, 2, audience_ids.first(1))

      expect(blast.reload.completed_at).to be_blank
      expect($redis.smembers(new_done_key)).to eq(["0"])
    ensure
      $redis.del(old_done_key, new_done_key) if old_done_key && new_done_key
    end

    it "does not stamp or re-send when a sibling already completed the blast" do
      blast = create(:blast, post: post_with_audience, completed_at: Time.current)
      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect_sent_count 0
      expect($redis.exists?(RedisKey.blast_done_slices(blast.id, partition_key))).to eq(false)
    end

    it "does not re-send members a prior attempt already marked sent in a non-opener resend" do
      post = create(:product_post, :published, seller: @seller, link: create(:product, user: @seller))
      sale = create(:purchase, link: post.link, seller: @seller)
      blast = create(:blast, :just_requested, post:, recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
      member_id = AudienceMember.where(seller_id: @seller).pluck(:id)

      # First attempt marked the recipient sent before failing; the retry hands the same id again.
      $redis.sadd(RedisKey.blast_sent_emails(blast.id), sale.email)

      described_class.new.perform(blast.id, partition_key, 0, 1, member_id)

      expect(PostSendgridApi.mails[sale.email]).to be_blank
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(RedisKey.blast_sent_emails(blast.id), RedisKey.blast_done_slices(blast.id, partition_key))
    end

    it "records an empty chunk as done so the blast still completes" do
      blast = create(:blast, :just_requested, post: post_with_audience)

      described_class.new.perform(blast.id, partition_key, 0, 1, [])

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_present
    end

    it "ignores deleted posts" do
      post = post_with_audience
      post.mark_deleted!
      blast = create(:blast, :just_requested, post:)
      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_blank
    end
  end
end
