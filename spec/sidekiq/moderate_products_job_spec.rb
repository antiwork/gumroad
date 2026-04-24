# frozen_string_literal: true

require "spec_helper"

describe ModerateProductsJob do
  let(:product1) { create(:product) }
  let(:product2) { create(:product) }
  let(:passed_result) { ContentModeration::ModerateRecordService::CheckResult.new(passed: true, reasons: []) }

  before do
    allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(passed_result)
  end

  it "runs moderation for each product in the given ids" do
    described_class.new.perform([product1.id, product2.id])

    expect(ContentModeration::ModerateRecordService).to have_received(:check).with(have_attributes(id: product1.id), :product)
    expect(ContentModeration::ModerateRecordService).to have_received(:check).with(have_attributes(id: product2.id), :product)
  end

  it "skips ids that no longer exist without raising" do
    missing_id = Link.maximum(:id).to_i + 10_000

    expect do
      described_class.new.perform([product1.id, missing_id])
    end.not_to raise_error

    expect(ContentModeration::ModerateRecordService).to have_received(:check).once
  end

  it "reports errors for individual products and continues processing the rest" do
    allow(ContentModeration::ModerateRecordService).to receive(:check).with(have_attributes(id: product1.id), :product)
      .and_raise(Faraday::TimeoutError, "Net::ReadTimeout")
    allow(ContentModeration::ModerateRecordService).to receive(:check).with(have_attributes(id: product2.id), :product)
      .and_return(passed_result)
    allow(ErrorNotifier).to receive(:notify)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform([product1.id, product2.id])

    expect(ErrorNotifier).to have_received(:notify).with(instance_of(Faraday::TimeoutError), context: { product_id: product1.id })
    expect(ContentModeration::ModerateRecordService).to have_received(:check).with(have_attributes(id: product2.id), :product)
  end

  it "enqueues to the low queue" do
    expect(described_class.sidekiq_options["queue"]).to eq(:low)
  end
end
