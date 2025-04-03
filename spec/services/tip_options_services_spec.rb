# frozen_string_literal: true

require "spec_helper"

RSpec.describe TipOptionsService, type: :service do
  describe ".get_tip_options" do
    context "when Redis has valid tip options" do
      before do
        $redis.set(RedisKey.tip_options, "[10, 20, 30]")
      end

      it "returns the parsed tip options" do
        expect(described_class.get_tip_options).to eq([10, 20, 30])
      end
    end

    context "when Redis has invalid JSON" do
      before do
        $redis.set(RedisKey.tip_options, "invalid_json")
      end

      it "returns the default tip options" do
        expect(described_class.get_tip_options).to eq(TipOptionsService::DEFAULT_TIP_OPTIONS)
      end
    end
    context "when Redis has invalid tip options" do
      before do
        $redis.set(RedisKey.tip_options, '[10,"bad",20]')
      end

      it "returns the default tip options" do
        expect(described_class.get_tip_options).to eq(TipOptionsService::DEFAULT_TIP_OPTIONS)
      end
    end

    context "when Redis has no tip options" do
      it "returns the default tip options" do
        expect(described_class.get_tip_options).to eq(TipOptionsService::DEFAULT_TIP_OPTIONS)
      end
    end
  end

  describe ".set_tip_options" do
    context "when options are valid" do
      it "sets the tip options in Redis" do
        described_class.set_tip_options([5, 15, 25])
        expect($redis.get(RedisKey.tip_options)).to eq("[5,15,25]")
      end
    end

    context "when options are invalid" do
      it "raises an ArgumentError" do
        expect { described_class.set_tip_options("invalid") }.to raise_error(ArgumentError, "Tip options must be an array of integers")
      end
    end
  end

  describe ".get_default_tip_option" do
    context "when Redis has a valid default tip option" do
      before do
        $redis.set(RedisKey.default_tip_option, "20")
      end

      it "returns the default tip option" do
        expect(described_class.get_default_tip_option).to eq(20)
      end
    end

    context "when Redis has an invalid default tip option" do
      before do
        $redis.set(RedisKey.default_tip_option, "invalid")
      end

      it "returns the default default tip option" do
        expect(described_class.get_default_tip_option).to eq(TipOptionsService::DEFAULT_DEFAULT_TIP_OPTION)
      end
    end

    context "when Redis has no default tip option" do
      it "returns the default default tip option" do
        expect(described_class.get_default_tip_option).to eq(TipOptionsService::DEFAULT_DEFAULT_TIP_OPTION)
      end
    end
  end

  describe ".set_default_tip_option" do
    context "when option is valid" do
      it "sets the default tip option in Redis" do
        described_class.set_default_tip_option(10)
        expect($redis.get(RedisKey.default_tip_option)).to eq("10")
      end
    end

    context "when option is invalid" do
      it "raises an ArgumentError" do
        expect { described_class.set_default_tip_option("invalid") }.to raise_error(ArgumentError, "Default tip option must be an integer")
      end
    end
  end
end
