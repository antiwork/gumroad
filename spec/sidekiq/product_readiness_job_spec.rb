# frozen_string_literal: true

require "spec_helper"

describe ProductReadinessJob do
  let(:product) { create(:product) }

  before { Rails.cache.clear }

  it "is enqueued on the low queue" do
    expect(described_class.sidekiq_options["queue"]).to eq(:low)
  end

  it "computes and caches readiness for the product" do
    expect_any_instance_of(ProductReadinessService).to receive(:call).and_call_original
    described_class.new.perform(product.id)
  end

  it "is a no-op when the product no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end
end
