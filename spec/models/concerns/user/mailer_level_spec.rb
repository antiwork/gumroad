# frozen_string_literal: true

require "spec_helper"

describe User::MailerLevel do
  describe "#mailer_level" do
    before do
      @creator = create(:user)
    end

    context "when creator belongs to level_1" do
      it "returns :level_1" do
        expect(@creator.mailer_level).to eq :level_1
      end

      it "returns :level_1 for negative sales_cents_total" do
        allow(@creator).to receive(:sales_cents_total).and_return(-20_000_00) # $-20K

        expect(@creator.mailer_level).to eq :level_1
      end
    end

    context "when creator belongs to level_2" do
      it "returns :level_2" do
        allow(@creator).to receive(:sales_cents_total).and_return(60_000_00) # $60K

        expect(@creator.mailer_level).to eq :level_2
      end


      it "returns :level_2 for very large sales_cents_total number" do
        allow(@creator).to receive(:sales_cents_total).and_return(800_000_000_00) # $800M

        expect(@creator.mailer_level).to eq :level_2
      end
    end

    describe "caching" do
      before do
        @redis_namespace = Redis::Namespace.new(:user_mailer_redis_namespace, redis: $redis)
      end

      it "sets the level in redis" do
        @creator.mailer_level

        expect(@redis_namespace.get(@creator.send(:mailer_level_cache_key))).to eq "level_1"
      end

      it "doesn't query elasticsearch when level is available in redis" do
        @redis_namespace.set("creator_mailer_level_#{@creator.id}", "level_2")
        expect(@creator).not_to receive(:sales_cents_total)

        level = @creator.mailer_level

        expect(level).to eq :level_2
      end

      it "caches the level in Memcached" do
        @creator.mailer_level

        expect(Rails.cache.read("creator_mailer_level_#{@creator.id}")).to eq :level_1
      end
    end
  end
end
