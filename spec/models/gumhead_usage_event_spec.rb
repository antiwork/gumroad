# frozen_string_literal: true

require "spec_helper"

describe GumheadUsageEvent do
  describe ".input_equivalent_tokens_today" do
    before do
      @user = create(:user)
    end

    it "weights cache reads at the Grok default so $0.50 reads do not count as Anthropic 0.1x" do
      described_class.create!(user: @user, model: "x-ai/grok-4.6", cache_read_input_tokens: 100)

      expect(described_class.input_equivalent_tokens_today(@user)).to eq(25)
    end

    it "uses configured cache multipliers instead of the hardcoded defaults" do
      described_class.create!(
        user: @user,
        model: "x-ai/grok-4.6",
        cache_creation_input_tokens: 40,
        cache_creation_1h_input_tokens: 10,
        cache_read_input_tokens: 100,
      )
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_CACHE_CREATION_COST_MULTIPLIER", described_class::CACHE_CREATION_COST_MULTIPLIER)
        .and_return(1.25)
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_CACHE_CREATION_1H_COST_MULTIPLIER", described_class::CACHE_CREATION_1H_COST_MULTIPLIER)
        .and_return(2)
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_CACHE_READ_COST_MULTIPLIER", described_class::CACHE_READ_COST_MULTIPLIER)
        .and_return(0.1)

      # 30 * 1.25 = 37.5 -> 38; 10 * 2 = 20; 100 * 0.1 = 10
      expect(described_class.input_equivalent_tokens_today(@user)).to eq(68)
    end
  end
end
