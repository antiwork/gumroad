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

  def activate_partition(blast, key = partition_key)
    $redis.set(RedisKey.blast_active_slice_partition(blast.id), key)
  end

  def expect_sent_count(count)
    expect(PostSendgridApi.mails.size).to eq(count)
  end

  describe "#perform" do
    it "sends only the handed chunk and records it as done" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      chunk_ids = audience_ids
      activate_partition(blast)

      described_class.new.perform(blast.id, partition_key, 0, 1, chunk_ids)

      expect_sent_count 3
      expect(PostSendgridApi.mails.keys).to contain_exactly("alpha@example.com", "bravo@example.com", "charlie@example.com")
      expect(blast.reload.completed_at).to be_present
      # Done-slices set is cleared by the completion stamp.
      expect($redis.exists?(RedisKey.blast_done_slices(blast.id, partition_key))).to eq(false)
    end

    it "decrements the pending recipient count the parent published" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      activate_partition(blast)
      pending_key = RedisKey.blast_pending_recipients(blast.id)
      $redis.set(pending_key, 3)

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect($redis.get(pending_key).to_i).to eq(0)
    ensure
      $redis.del(pending_key)
    end

    it "stamps completed_at only when the last distinct chunk finishes, even out of order" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      activate_partition(blast)
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
      activate_partition(blast)
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

    it "does not let an old partition complete after a replacement appears mid-send" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      old_partition_key = "old-partition"
      replacement_partition_key = "replacement-partition"
      old_done_key = RedisKey.blast_done_slices(blast.id, old_partition_key)
      active_key = RedisKey.blast_active_slice_partition(blast.id)
      activate_partition(blast, old_partition_key)
      $redis.sadd(old_done_key, 0)
      allow_any_instance_of(described_class).to receive(:send_members) do
        $redis.set(active_key, replacement_partition_key)
      end

      described_class.new.perform(blast.id, old_partition_key, 1, 2, audience_ids.first(1))

      expect(blast.reload.completed_at).to be_blank
      expect($redis.get(active_key)).to eq(replacement_partition_key)
      expect($redis.smembers(old_done_key)).to contain_exactly("0", "1")
    ensure
      $redis.del(old_done_key, active_key) if old_done_key && active_key
    end

    it "holds the partition mutation lock while stamping completion" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      active_key = RedisKey.blast_active_slice_partition(blast.id)
      lock_key = RedisKey.blast_slice_partition_mutation_lock(blast.id)
      activate_partition(blast)
      lock_was_held = nil
      job = described_class.new
      allow(job).to receive(:send_members)
      allow(job).to receive(:mark_blast_as_completed) do
        lock_was_held = !$redis.set(lock_key, "replacement", nx: true, ex: 10)
        blast.update!(completed_at: Time.current)
      end

      job.perform(blast.id, partition_key, 0, 1, audience_ids.first(1))

      expect(lock_was_held).to be(true)
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(active_key, lock_key) if active_key && lock_key
    end

    it "ignores children from an older partition after the parent creates a replacement partition" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      old_partition_key = "old-partition"
      old_done_key = RedisKey.blast_done_slices(blast.id, old_partition_key)
      activate_partition(blast, partition_key)
      $redis.sadd(old_done_key, 0)

      described_class.new.perform(blast.id, old_partition_key, 1, 2, [])

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_blank
      expect($redis.smembers(old_done_key)).to eq(["0"])
    ensure
      $redis.del(old_done_key, RedisKey.blast_active_slice_partition(blast.id)) if old_done_key && blast
    end

    it "skips a member whose email was blanked after the partition was created" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      chunk_ids = audience_ids
      AudienceMember.find_by!(seller: @seller, email: "bravo@example.com").update_column(:email, "")
      activate_partition(blast)

      described_class.new.perform(blast.id, partition_key, 0, 1, chunk_ids)

      expect_sent_count 2
      expect(PostSendgridApi.mails.keys).to contain_exactly("alpha@example.com", "charlie@example.com")
      expect(blast.reload.completed_at).to be_present
    end

    it "reschedules itself past the claim expiry instead of failing when another copy holds the chunk" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:, recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
      activate_partition(blast)
      $redis.set(RedisKey.blast_slice_claim(blast.id, partition_key, 0), "live-copy-jid", ex: 600)

      expect { described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids.first(1)) }.not_to raise_error

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_blank
      expect(described_class.jobs.size).to eq(1)
      requeued = described_class.jobs.sole
      expect(requeued["args"]).to eq([blast.id, partition_key, 0, 1, audience_ids.first(1)])
      expect(requeued["at"]).to be_within(2).of((600 + described_class::CLAIM_RECHECK_SLACK.to_i).seconds.from_now.to_f)
      # The held claim was left alone.
      expect($redis.get(RedisKey.blast_slice_claim(blast.id, partition_key, 0))).to eq("live-copy-jid")
    ensure
      $redis.del(RedisKey.blast_slice_claim(blast.id, partition_key, 0), RedisKey.blast_active_slice_partition(blast.id)) if blast
    end

    it "renews its claim after loading the chunk members" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      claim_key = RedisKey.blast_slice_claim(blast.id, partition_key, 0)
      ttl_after_load = nil
      allow_any_instance_of(described_class).to receive(:load_chunk_members).and_wrap_original do |original, *args|
        # Pretend the load ran long enough for the claim to be close to lapsing.
        $redis.expire(claim_key, 5)
        original.call(*args)
      end
      allow_any_instance_of(described_class).to receive(:send_members) { ttl_after_load = $redis.ttl(claim_key) }

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect(ttl_after_load).to be > (described_class::CHUNK_CLAIM_TTL.to_i - 30)
    end

    it "keeps the member-load statement cap below the claim lifetime" do
      expect(described_class::CHUNK_LOAD_TIMEOUT).to be < described_class::CHUNK_CLAIM_TTL
    end

    it "sends the chunk once the previous copy's claim has lapsed" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      # Redis expiry runs on wall-clock time, not the frozen test clock.
      $redis.set(RedisKey.blast_slice_claim(blast.id, partition_key, 0), "killed-copy-token", px: 20)
      sleep 0.05

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect_sent_count 3
      expect(blast.reload.completed_at).to be_present
    end

    it "finalizes when retrying a chunk after every chunk was already recorded" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      activate_partition(blast)
      done_key = RedisKey.blast_done_slices(blast.id, partition_key)
      $redis.sadd(done_key, [0, 1])

      described_class.new.perform(blast.id, partition_key, 1, 2, [])

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_present
      expect($redis.exists?(done_key)).to eq(false)
    ensure
      $redis.del(done_key, RedisKey.blast_active_slice_partition(blast.id)) if done_key && blast
    end

    it "skips a chunk that already recorded completion in this partition" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:, recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
      activate_partition(blast)
      done_key = RedisKey.blast_done_slices(blast.id, partition_key)
      $redis.sadd(done_key, 0)

      described_class.new.perform(blast.id, partition_key, 0, 2, audience_ids.first(1))

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_blank
    ensure
      $redis.del(done_key, RedisKey.blast_active_slice_partition(blast.id)) if done_key && blast
    end

    it "stores a per-execution token as the chunk claim value" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      activate_partition(blast)
      claim_key = RedisKey.blast_slice_claim(blast.id, partition_key, 0)
      claim_value = nil
      allow_any_instance_of(described_class).to receive(:send_members) { claim_value = $redis.get(claim_key) }
      job = described_class.new
      job.jid = "claiming-jid"

      job.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect(claim_value).to be_present
      expect(claim_value).not_to eq("claiming-jid")
    end

    it "does not let the same jid steal a held claim" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      $redis.set(RedisKey.blast_slice_claim(blast.id, partition_key, 0), "live-execution-token")
      job = described_class.new
      job.jid = "requeued-jid"

      job.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_blank
      expect(described_class.jobs.size).to eq(1)
    ensure
      $redis.del(RedisKey.blast_slice_claim(blast.id, partition_key, 0), RedisKey.blast_active_slice_partition(blast.id)) if blast
    end

    it "does not let a different jid steal a held claim" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      $redis.set(RedisKey.blast_slice_claim(blast.id, partition_key, 0), "jid-a")
      job = described_class.new
      job.jid = "jid-b"

      job.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_blank
      expect(described_class.jobs.size).to eq(1)
    ensure
      $redis.del(RedisKey.blast_slice_claim(blast.id, partition_key, 0), RedisKey.blast_active_slice_partition(blast.id)) if blast
    end

    it "releases the chunk claim when delivery raises" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      claim_key = RedisKey.blast_slice_claim(blast.id, partition_key, 0)
      allow_any_instance_of(described_class).to receive(:send_members).and_raise(StandardError.new("send failed"))

      expect { described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids.first(1)) }.to raise_error(StandardError, "send failed")

      expect($redis.exists?(claim_key)).to be(false)
    ensure
      $redis.del(claim_key, RedisKey.blast_active_slice_partition(blast.id)) if claim_key && blast
    end

    it "does not release a successor claim after this execution loses the lease" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      claim_key = RedisKey.blast_slice_claim(blast.id, partition_key, 0)
      allow_any_instance_of(described_class).to receive(:send_members) do
        $redis.set(claim_key, "successor-token")
        raise StandardError, "send failed"
      end

      expect { described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids.first(1)) }.to raise_error(StandardError, "send failed")

      expect($redis.get(claim_key)).to eq("successor-token")
    ensure
      $redis.del(claim_key, RedisKey.blast_active_slice_partition(blast.id)) if claim_key && blast
    end

    it "rehydrates the handed ids in bounded batches" do
      stub_const("#{described_class}::CHUNK_REVALIDATION_SLICE_SIZE", 2)
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      slice_sizes = []
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        slice_sizes << kwargs[:ids].size
        original.call(**kwargs)
      end
      allow_any_instance_of(described_class).to receive(:send_members)

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect(slice_sizes).to eq([2, 1])
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
      activate_partition(blast)
      member_id = AudienceMember.where(seller_id: @seller).pluck(:id)

      # First attempt marked the recipient sent before failing; the retry hands the same id again.
      $redis.sadd(RedisKey.blast_sent_emails(blast.id), sale.email)

      described_class.new.perform(blast.id, partition_key, 0, 1, member_id)

      expect(PostSendgridApi.mails[sale.email]).to be_blank
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(RedisKey.blast_sent_emails(blast.id), RedisKey.blast_done_slices(blast.id, partition_key))
    end

    it "strips tags from purchase product names in prepare_recipients" do
      product = create(:product, user: @seller, name: "<b>Shattered</b> Samples")
      post = create(:product_post, :published, seller: @seller, link: product, bought_products: [product.unique_permalink])
      sale = create(:purchase, link: product, seller: @seller, email: "buyer@example.com")
      blast = create(:blast, :just_requested, post:)
      member = AudienceMember.filter(
        seller_id: @seller.id,
        params: post.audience_members_filter_params,
        with_ids: true,
        ids: AudienceMember.where(seller_id: @seller, email: sale.email).pluck(:id)
      ).select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
      job = described_class.new
      job.instance_variable_set(:@post, post)
      job.instance_variable_set(:@blast, blast)

      recipients = job.send(:prepare_recipients, member)

      expect(recipients.map { _1[:product_name] }).to eq(["Shattered Samples"])
    end

    it "does not leave SentPostEmail rows when preparing recipients raises" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      allow_any_instance_of(described_class).to receive(:prepare_recipients).and_raise(NoMethodError, "undefined method 'full_sanitizer'")

      expect do
        described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)
      end.to raise_error(NoMethodError, /full_sanitizer/)

      expect(SentPostEmail.where(post:).count).to eq(0)
    end

    it "does not leave SentPostEmail rows when the worker is hard-killed before the provider accepts" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      # A kill signal is not a StandardError and skips any rescue; the rows must simply not exist yet.
      allow(PostSendgridApi).to receive(:process).and_raise(Sidekiq::Shutdown)

      expect do
        described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)
      end.to raise_error(Sidekiq::Shutdown)

      expect(SentPostEmail.where(post:).count).to eq(0)
    end

    it "records recipients as sent only after the provider accepted them" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      rows_at_send = nil
      allow(PostSendgridApi).to receive(:process).and_wrap_original do |original, **kwargs|
        rows_at_send = SentPostEmail.where(post:).count
        original.call(**kwargs)
      end

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect(rows_at_send).to eq(0)
      expect(SentPostEmail.where(post:).count).to eq(3)
      expect_sent_count 3
    end

    it "re-sends recipients a killed copy left without a row, and skips the ones it recorded" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      # First copy delivered alpha (row written) then died before bravo/charlie.
      SentPostEmail.create!(post:, email: "alpha@example.com")

      described_class.new.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect(PostSendgridApi.mails.keys).to contain_exactly("bravo@example.com", "charlie@example.com")
      expect(SentPostEmail.where(post:).count).to eq(3)
      expect(blast.reload.completed_at).to be_present
    end

    it "drops an address another sender recorded between the chunk filter and the provider call" do
      post = post_with_audience
      blast = create(:blast, :just_requested, post:)
      activate_partition(blast)
      job = described_class.new
      allow(job).to receive(:remove_already_emailed_members).and_wrap_original do |original|
        original.call
        SentPostEmail.create!(post:, email: "bravo@example.com")
      end

      job.perform(blast.id, partition_key, 0, 1, audience_ids)

      expect(PostSendgridApi.mails.keys).to contain_exactly("alpha@example.com", "charlie@example.com")
      expect(SentPostEmail.where(post:).count).to eq(3)
    end

    it "exposes SanitizeHelper class methods used by strip_tags" do
      expect(described_class).to respond_to(:full_sanitizer)
      expect(described_class.new.send(:strip_tags, "<b>Hi</b>")).to eq("Hi")
    end

    it "records an empty chunk as done so the blast still completes" do
      blast = create(:blast, :just_requested, post: post_with_audience)
      activate_partition(blast)

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
