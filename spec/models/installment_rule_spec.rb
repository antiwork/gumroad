# frozen_string_literal: true

require "spec_helper"

describe InstallmentRule do
  describe "version" do
    before do
      @product = create(:product)
      @post = create(:installment, link: @product, installment_type: "product")
      @post_rule = create(:installment_rule, installment: @post, to_be_published_at: 1.week.from_now)
    end

    it "has the installment_rule starting version be 1" do
      expect(@post_rule.reload.version).to eq(1)
    end

    it "increments the version when to_be_published_at changes" do
      expect do
        @post_rule.update(to_be_published_at: 1.month.from_now)
      end.to change { @post_rule.reload.version }.by(1)
      expect(@post_rule.reload.version).to eq(2)
    end

    it "increments the version if delayed_delivery_time is changed" do
      expect do
        @post_rule.delayed_delivery_time = 100
        @post_rule.save
      end.to change { @post_rule.reload.version }.by(1)
      expect(@post_rule.reload.version).to eq(2)
    end

    it "publishes the new version to the shared delivery cache" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      rule.update!(delayed_delivery_time: 100)

      expect(described_class.cached_version(post.id)).to eq(rule.version)
    end

    it "publishes a pending version before its transaction commits" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      pending_token_key = RedisKey.workflow_installment_rule_pending_token(post.id)

      described_class.transaction do
        rule.update!(delayed_delivery_time: 100)
        expect(described_class.cached_version(post.id)).to eq(rule.version)
        expect($redis.get(pending_token_key)).to be_present
        raise ActiveRecord::Rollback
      end

      expect(described_class.cached_version(post.id)).to be_nil
      expect($redis.get(pending_token_key)).to be_nil
    end

    it "bounds orphaned pending markers and expires the owner first" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      version_key = RedisKey.workflow_installment_rule_version(post.id)
      owner_key = RedisKey.workflow_installment_rule_pending_token(post.id)

      described_class.transaction do
        rule.update!(delayed_delivery_time: 2.days)

        expect($redis.ttl(owner_key)).to be_between(1, described_class::PENDING_OWNER_CACHE_TTL)
        expect($redis.ttl(version_key)).to be > $redis.ttl(owner_key)
        raise ActiveRecord::Rollback
      end
    end

    it "cleans pending ownership when an earlier instance only changes metadata" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      first_instance = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      pending_token_key = RedisKey.workflow_installment_rule_pending_token(post.id)

      described_class.transaction do
        first_instance.update!(time_period: "week")
        described_class.find(first_instance.id).update!(delayed_delivery_time: 2.days)
      end

      expect($redis.get(pending_token_key)).to be_nil
      expect(described_class.cached_version(post.id)).to eq(first_instance.reload.version)
    end

    it "promotes the highest version saved through separate instances" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      first_instance = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      pending_token_key = RedisKey.workflow_installment_rule_pending_token(post.id)

      described_class.transaction do
        first_instance.update!(delayed_delivery_time: 2.days)
        described_class.find(first_instance.id).update!(delayed_delivery_time: 3.days)
      end

      expect($redis.get(pending_token_key)).to be_nil
      expect(described_class.cached_version(post.id)).to eq(first_instance.reload.version)
    end

    it "keeps a same-version marker owned by a newer transaction" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      pending_version = rule.version + 1
      old_token = SecureRandom.uuid
      new_token = SecureRandom.uuid
      $redis.set(RedisKey.workflow_installment_rule_version(post.id), pending_version)
      $redis.set(RedisKey.workflow_installment_rule_pending_token(post.id), new_token)

      described_class.clear_pending_version(
        installment_id: post.id,
        installment_rule_id: rule.id,
        token: old_token
      )

      expect(described_class.cached_version(post.id)).to eq(pending_version)
      expect($redis.get(RedisKey.workflow_installment_rule_pending_token(post.id))).to eq(new_token)
    end

    it "does not promote over a same-version marker owned by a newer transaction" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      pending_version = rule.version + 1
      old_token = SecureRandom.uuid
      new_token = SecureRandom.uuid
      version_key = RedisKey.workflow_installment_rule_version(post.id)
      owner_key = RedisKey.workflow_installment_rule_pending_token(post.id)
      $redis.set(version_key, pending_version, ex: described_class::PENDING_VERSION_CACHE_TTL)
      $redis.set(owner_key, new_token, ex: described_class::PENDING_OWNER_CACHE_TTL)

      described_class.promote_pending_version(
        installment_id: post.id,
        installment_rule_id: rule.id,
        version: pending_version,
        token: old_token
      )

      expect(described_class.cached_version(post.id)).to eq(pending_version)
      expect($redis.get(owner_key)).to eq(new_token)
      expect($redis.ttl(version_key)).to be <= described_class::PENDING_VERSION_CACHE_TTL
    end

    it "does not let a normal cache fill clear pending ownership" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      token = SecureRandom.uuid
      version_key = RedisKey.workflow_installment_rule_version(post.id)
      owner_key = RedisKey.workflow_installment_rule_pending_token(post.id)
      $redis.set(version_key, rule.version, ex: described_class::PENDING_VERSION_CACHE_TTL)
      $redis.set(owner_key, token, ex: described_class::PENDING_OWNER_CACHE_TTL)

      rule.cache_version!

      expect($redis.get(owner_key)).to eq(token)
      expect($redis.ttl(version_key)).to be <= described_class::PENDING_VERSION_CACHE_TTL
    end

    it "publishes the pending version before updating the database row" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      observed_version = nil
      observer = lambda do |*, payload|
        next unless payload[:name] == "InstallmentRule Update"

        observed_version = described_class.cached_version(post.id)
      end

      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
        rule.update!(delayed_delivery_time: 2.days)
      end

      expect(observed_version).to eq(rule.version)
    end

    it "returns the newer effective version when its cache write loses" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      newer_version = rule.version + 1
      $redis.set(RedisKey.workflow_installment_rule_version(post.id), newer_version)

      expect(rule.cache_version!).to eq(newer_version)
      expect(described_class.cached_version(post.id)).to eq(newer_version)
    end

    it "advances from the committed version when the instance is stale" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      stale_rule = described_class.find(rule.id)
      rule.update!(delayed_delivery_time: 2.days)

      stale_rule.advance_version!

      expect(stale_rule.version).to eq(rule.version + 1)
      expect(described_class.cached_version(post.id)).to eq(stale_rule.version)
    end

    it "does not fail after the database commit if Redis is unavailable" do
      error = Redis::CannotConnectError.new("unavailable")
      allow(@post_rule).to receive(:cache_version!).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, installment_rule_id: @post_rule.id)

      expect { @post_rule.send(:cache_committed_version) }.not_to raise_error
    end

    it "does not fail after the database commit if RedisClient raises an error" do
      error = RedisClient::Error.new("unavailable")
      allow(@post_rule).to receive(:cache_version!).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, installment_rule_id: @post_rule.id)

      expect { @post_rule.send(:cache_committed_version) }.not_to raise_error
    end

    it "does not fail database rollback cleanup if Redis is unavailable" do
      error = Redis::CannotConnectError.new("unavailable")
      allow($redis).to receive(:eval).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, installment_rule_id: @post_rule.id)

      expect do
        described_class.clear_pending_version(
          installment_id: @post_rule.installment_id,
          installment_rule_id: @post_rule.id,
          token: SecureRandom.uuid
        )
      end.not_to raise_error
    end

    it "does not require Redis before committing a new rule" do
      post = create(:installment, link: @product, installment_type: "product")
      rule = build(:installment_rule, installment: post, to_be_published_at: 1.week.from_now)
      expect(rule).not_to receive(:cache_version!)

      expect { rule.save! }.not_to raise_error
    end

    it "does not require Redis before committing a change that keeps the version" do
      workflow = create(:workflow, seller: @product.user, link: @product)
      post = create(:installment, link: @product, workflow:)
      rule = create(:installment_rule, installment: post, delayed_delivery_time: 1.day)
      error = RedisClient::Error.new("unavailable")
      allow(rule).to receive(:cache_version!).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, installment_rule_id: rule.id)

      expect { rule.update!(time_period: "week") }.not_to raise_error
    end

    it "does not cache versions for scheduled post rules" do
      expect(@post_rule).not_to receive(:cache_version!)

      @post_rule.update!(to_be_published_at: 1.month.from_now)
    end

    it "does not increment the version if period is changed" do
      expect do
        @post_rule.time_period = "DAY"
        @post_rule.save
      end.to_not change { @post_rule.reload.version }
    end

    it "does not increment the version if period is changed" do
      expect do
        @post_rule.time_period = "DAY"
        @post_rule.save
      end.to_not change { @post_rule.reload.version }
    end
  end

  describe "displayable_time_duration" do
    before do
      @product = create(:product)
      @post = create(:installment, link: @product, installment_type: "product")
      @post_rule = create(:installment_rule, installment: @post, delayed_delivery_time: 1.week, time_period: "week")
    end

    it "returns the correct duration based on the time period" do
      expect(@post_rule.displayable_time_duration).to eq(1)
      @post_rule.update(delayed_delivery_time: 2.weeks, time_period: "day")
      expect(@post_rule.displayable_time_duration).to eq(14)
      @post_rule.update(delayed_delivery_time: 2.hours, time_period: "hour")
      expect(@post_rule.displayable_time_duration).to eq(2)
      @post_rule.update(delayed_delivery_time: 1.month, time_period: "month")
      expect(@post_rule.displayable_time_duration).to eq(1)
    end
  end

  describe "validations" do
    describe "to_be_published_at_cannot_be_in_the_past" do
      before do
        post = create(:post, workflow: create(:audience_workflow))
        @post_rule = create(:installment_rule, to_be_published_at: nil, installment: post)
      end

      it "allows to_be_published_at to be nil" do
        expect(@post_rule.to_be_published_at).to be_nil
        expect(@post_rule).to be_valid
      end

      it "disallows to_be_published_at to be in the past" do
        @post_rule.to_be_published_at = Time.current
        expect(@post_rule).not_to be_valid
        expect(@post_rule.errors.full_messages).to include("Please select a date and time in the future.")
      end

      context "when about to be marked as deleted" do
        it "allows to_be_published_at to be in the past" do
          @post_rule.to_be_published_at = Time.current
          @post_rule.deleted_at = Time.current
          expect(@post_rule).to be_valid
        end
      end
    end

    describe "to_be_published_at_must_exist_for_non_workflow_posts" do
      it "disallows to_be_published_at to be nil" do
        post_rule = build(:installment_rule, to_be_published_at: nil)
        expect(post_rule).not_to be_valid
        expect(post_rule.errors.full_messages).to include("Please select a date and time in the future.")
      end
    end
  end
end
