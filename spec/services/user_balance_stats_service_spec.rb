# frozen_string_literal: true

require "spec_helper"

describe UserBalanceStatsService do
  let(:user) { create(:user) }
  let(:instance) { described_class.new(user:) }
  let(:example_values) { { foo: "bar", nested: { key1: { key2: "value2" } }, records: [{ id: 1, name: "first" }, { id: 2, name: "second" }] } }

  describe "#fetch_overview" do
    let(:now) { Time.zone.local(2024, 6, 15, 12, 0, 0) }
    let(:overview) do
      {
        balance: 12_34,
        last_seven_days_sales_total: 10_00,
        last_28_days_sales_total: 40_00,
        sales_cents_total: 90_00,
      }
    end

    before do
      travel_to(now)
      allow(user).to receive(:unpaid_balance_cents).and_return(overview[:balance])
      allow(user).to receive(:sales_cents_total).with(no_args).and_return(overview[:sales_cents_total])
      allow(user).to receive(:sales_cents_total).with(after: 7.days.ago).and_return(overview[:last_seven_days_sales_total])
      allow(user).to receive(:sales_cents_total).with(after: 28.days.ago).and_return(overview[:last_28_days_sales_total])
    end

    context "when the seller is not cacheable" do
      before { allow(instance).to receive(:should_use_cache?).and_return(false) }

      it "returns the four overview scalars without building the payouts payload" do
        expect(instance).not_to receive(:generate)
        expect(instance.fetch_overview).to eq(overview)
      end
    end

    context "when the seller is cacheable and the cache is cold" do
      before { allow(instance).to receive(:should_use_cache?).and_return(true) }

      it "computes the four scalars and enqueues a cache refresh" do
        expect(instance).not_to receive(:generate)
        expect(instance.fetch_overview).to eq(overview)
        expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(user.id)
      end
    end

    context "when the seller is cacheable and the cache is warm" do
      let(:cached_payload) do
        {
          generated_at: now,
          next_payout_period_data: { status: "payable" },
          processing_payout_periods_data: [],
          overview:,
          payout_period_data: { 1 => { amount: 99 } },
          payments: [],
          is_paginating: false,
        }
      end

      before do
        allow(instance).to receive(:should_use_cache?).and_return(true)
        $redis.setex(instance.send(:cache_key), 48.hours.to_i, cached_payload.to_json)
      end

      it "returns only the nested overview hash" do
        expect(instance).not_to receive(:generate)
        expect(instance).not_to receive(:overview_stats)
        result = instance.fetch_overview
        expect(result).to eq(overview)
        expect(result.keys).to match_array(overview.keys)
        expect(result).not_to have_key(:payout_period_data)
        expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(user.id)
      end
    end
  end

  describe "#fetch_payout_periods" do
    let(:payout_periods) do
      {
        next_payout_period_data: { status: "not_payable" },
        processing_payout_periods_data: [],
      }
    end

    before do
      allow(instance).to receive(:payout_periods_stats).and_return(payout_periods)
    end

    context "when the seller is not cacheable" do
      before { allow(instance).to receive(:should_use_cache?).and_return(false) }

      it "returns the two payout period keys without building the rest of the payload" do
        expect(instance).not_to receive(:generate)
        expect(instance.fetch_payout_periods).to eq(payout_periods)
      end
    end

    context "when the seller is cacheable and the cache is cold" do
      before { allow(instance).to receive(:should_use_cache?).and_return(true) }

      it "builds the payout periods and enqueues a cache refresh" do
        expect(instance).not_to receive(:generate)
        expect(instance.fetch_payout_periods).to eq(payout_periods)
        expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(user.id)
      end
    end

    context "when the seller is cacheable and the cache is warm" do
      let(:cached_payload) do
        payout_periods.merge(
          generated_at: Time.current,
          overview: { balance: 12_34 },
        )
      end

      before do
        allow(instance).to receive(:should_use_cache?).and_return(true)
        $redis.setex(instance.send(:cache_key), 48.hours.to_i, cached_payload.to_json)
      end

      it "returns only the two payout period keys out of the cached payload" do
        expect(instance).not_to receive(:generate)
        expect(instance).not_to receive(:payout_periods_stats)
        result = instance.fetch_payout_periods

        expect(result.keys).to match_array(%i[next_payout_period_data processing_payout_periods_data])
        expect(result).not_to have_key(:overview)
        expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(user.id)
      end
    end
  end

  describe "#generate" do
    it "builds only the keys the two readers slice out of the cached payload" do
      user = create(:user)
      now = Time.zone.local(2020, 1, 1)
      travel_to(now)
      generated = described_class.new(user:).send(:generate)
      expect(generated).to be_a(Hash)
      expect(generated.keys).to match_array(
        [:generated_at, :overview, :next_payout_period_data, :processing_payout_periods_data]
      )
      expect(generated.fetch(:generated_at)).to eq(now)
    end

    describe "next_payout_period_data" do
      let(:user) { create(:compliant_user, unpaid_balance_cents: 10_01) }

      before do
        create(:merchant_account, user:)
        create(:ach_account, user:, stripe_bank_account_id: "ba_bankaccountid")
        create(:user_compliance_info, user:)
      end

      let(:generated) { described_class.new(user:).send(:generate) }

      context "when there is no standard payout processing" do
        it "returns the next payout period data" do
          expect(generated.fetch(:next_payout_period_data)).not_to eq(nil)
        end
      end

      context "when an instant payout is processing" do
        before do
          create(
            :payment,
            user:,
            processor: "STRIPE",
            processor_fee_cents: 10,
            stripe_transfer_id: "tr_1234",
            stripe_connect_account_id: "acct_1234",
            json_data: { type: Payouts::PAYOUT_TYPE_INSTANT }
          )
        end

        it "returns the next payout period data" do
          expect(generated.fetch(:next_payout_period_data)).not_to eq(nil)
        end
      end

      context "when a standard payout is processing" do
        before do
          create(
            :payment,
            user:,
            processor: "STRIPE",
            processor_fee_cents: 10,
            stripe_transfer_id: "tr_1234",
            stripe_connect_account_id: "acct_1234",
            json_data: { type: Payouts::PAYOUT_TYPE_STANDARD }
          )
        end

        it "returns the next payout period data as nil" do
          expect(generated.fetch(:next_payout_period_data)).to eq(nil)
        end
      end
    end

    describe "processing_payout_periods_data" do
      let(:user) { create(:compliant_user, unpaid_balance_cents: 10_01) }

      before do
        create(:merchant_account, user:)
        create(:ach_account, user:, stripe_bank_account_id: "ba_bankaccountid")
        create(:user_compliance_info, user:)
      end

      let(:generated) { described_class.new(user:).send(:generate) }

      context "when there are no processing payouts" do
        it "returns an empty array" do
          expect(generated.fetch(:processing_payout_periods_data)).to eq([])
        end
      end

      context "when there are multiple processing payouts" do
        before do
          create(:payment, user:, processor: "STRIPE", processor_fee_cents: 10, stripe_transfer_id: "tr_1234", stripe_connect_account_id: "acct_1234", json_data: { payout_type: Payouts::PAYOUT_TYPE_INSTANT })
          create(:payment, user:, processor: "STRIPE", processor_fee_cents: 10, stripe_transfer_id: "tr_1235", stripe_connect_account_id: "acct_1235", json_data: { payout_type: Payouts::PAYOUT_TYPE_STANDARD })
        end

        it "returns the processing payout period data" do
          processing_payout_periods_data = generated.fetch(:processing_payout_periods_data)
          expect(processing_payout_periods_data.size).to eq(2)
          expect(processing_payout_periods_data.map { _1.fetch(:type) }).to match_array([Payouts::PAYOUT_TYPE_INSTANT, Payouts::PAYOUT_TYPE_STANDARD])
        end
      end
    end
  end

  describe "#should_use_cache?" do
    context "when user is large seller" do
      before do
        stub_const("#{described_class}::DEFAULT_SALES_CACHING_THRESHOLD", 100)
        user.current_sign_in_at = 1.day.ago
        user.save!
        expect(described_class).to receive(:cacheable_users).and_call_original
      end

      context "with sales count below threshold" do
        it "returns false" do
          create(:large_seller, user:, sales_count: 50)
          expect(instance.send(:should_use_cache?)).to eq(false)
        end
      end

      context "with sales count above threshold" do
        it "returns true" do
          create(:large_seller, user:, sales_count: 200)
          expect(instance.send(:should_use_cache?)).to eq(true)
        end
      end
    end

    context "when user is not a large seller" do
      it "returns false" do
        expect(instance.send(:should_use_cache?)).to eq(false)
      end
    end
  end

  describe "#write_cache" do
    it "writes generated values" do
      expect(instance.send(:read_cache)).to eq(nil)
      expect(instance).to receive(:generate).and_return(example_values)
      instance.write_cache
      expect(instance.send(:read_cache)).to eq(example_values)
    end
  end

  describe "#read_cache" do
    it "reads cached values" do
      expect(instance.send(:read_cache)).to eq(nil)
      expect(instance).to receive(:generate).and_return(example_values)
      instance.write_cache
      expect(instance.send(:read_cache)).to eq(example_values)
    end
  end

  describe ".cacheable_users" do
    it "returns correct list of users" do
      user_1 = create(:large_seller, sales_count: 200, user: build(:user, current_sign_in_at: 10.days.ago)).user
      user_2 = create(:large_seller, sales_count: 200, user: build(:user, current_sign_in_at: 3.days.ago)).user
      user_3 = create(:large_seller, sales_count: 50, user: build(:user, current_sign_in_at: 10.days.ago)).user
      user_4 = create(:large_seller, sales_count: 50, user: build(:user, current_sign_in_at: 3.days.ago)).user
      # With default values
      stub_const("#{described_class}::DEFAULT_SALES_CACHING_THRESHOLD", 100)
      expect(described_class.cacheable_users).to match_array([user_1, user_2])
      # With custom redis set values
      $redis.set(RedisKey.balance_stats_sales_caching_threshold, 40)
      expect(described_class.cacheable_users).to match_array([user_1, user_2, user_3, user_4])
      $redis.sadd(RedisKey.balance_stats_users_excluded_from_caching, [user_1.id, user_3.id])
      expect(described_class.cacheable_users).to match_array([user_2, user_4])
    end
  end
end
