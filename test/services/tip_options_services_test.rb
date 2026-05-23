# frozen_string_literal: true

require "test_helper"

class TipOptionsServiceTest < ActiveSupport::TestCase
  self.described_class = TipOptionsService



  context_ TipOptionsService, type: :service do
  context_ ".get_tip_options" do
  context_ "when Redis has valid tip options" do
        before do
          $redis.set(RedisKey.tip_options, "[10, 20, 30]")
        end

  test "returns the parsed tip options" do
          expect(described_class.get_tip_options).to eq([10, 20, 30])
        end
      end

  context_ "when Redis has invalid JSON" do
        before do
          $redis.set(RedisKey.tip_options, "invalid_json")
        end

  test "returns the default tip options" do
          expect(described_class.get_tip_options).to eq(TipOptionsService::DEFAULT_TIP_OPTIONS)
        end
      end
  context_ "when Redis has invalid tip options" do
        before do
          $redis.set(RedisKey.tip_options, '[10,"bad",20]')
        end

  test "returns the default tip options" do
          expect(described_class.get_tip_options).to eq(TipOptionsService::DEFAULT_TIP_OPTIONS)
        end
      end

  context_ "when Redis has no tip options" do
  test "returns the default tip options" do
          expect(described_class.get_tip_options).to eq(TipOptionsService::DEFAULT_TIP_OPTIONS)
        end
      end
    end

  context_ ".set_tip_options" do
  context_ "when options are valid" do
  test "sets the tip options in Redis" do
          described_class.set_tip_options([5, 15, 25])
          expect($redis.get(RedisKey.tip_options)).to eq("[5,15,25]")
        end
      end

  context_ "when options are invalid" do
  test "raises an ArgumentError" do
          expect { described_class.set_tip_options("invalid") }.to raise_error(ArgumentError, "Tip options must be an array of integers")
        end
      end
    end

  context_ ".get_default_tip_option" do
  context_ "when Redis has a valid default tip option" do
        before do
          $redis.set(RedisKey.default_tip_option, "20")
        end

  test "returns the default tip option" do
          expect(described_class.get_default_tip_option).to eq(20)
        end
      end

  context_ "when Redis has an invalid default tip option" do
        before do
          $redis.set(RedisKey.default_tip_option, "invalid")
        end

  test "returns the default default tip option" do
          expect(described_class.get_default_tip_option).to eq(TipOptionsService::DEFAULT_DEFAULT_TIP_OPTION)
        end
      end

  context_ "when Redis has no default tip option" do
  test "returns the default default tip option" do
          expect(described_class.get_default_tip_option).to eq(TipOptionsService::DEFAULT_DEFAULT_TIP_OPTION)
        end
      end
    end

  context_ ".set_default_tip_option" do
  context_ "when option is valid" do
  test "sets the default tip option in Redis" do
          described_class.set_default_tip_option(10)
          expect($redis.get(RedisKey.default_tip_option)).to eq("10")
        end
      end

  context_ "when option is invalid" do
  test "raises an ArgumentError" do
          expect { described_class.set_default_tip_option("invalid") }.to raise_error(ArgumentError, "Default tip option must be an integer")
        end
      end
    end
  end
end
