# frozen_string_literal: true

describe FlushInstallmentDeliveredDeltasJob do
  let(:installment) { create(:installment, customer_count: 4) }

  it "folds buffered increments into one customer_count update" do
    expect do
      installment.increment_total_delivered(by: 2)
      installment.increment_total_delivered(by: 3)
    end.not_to change { installment.reload.customer_count }

    expect do
      described_class.new.perform
    end.to change { installment.reload.customer_count }.from(4).to(9)
  end

  it "writes through immediately when Redis is down" do
    allow($redis).to receive(:multi).and_raise(Redis::BaseError)
    expect do
      installment.increment_total_delivered(by: 2)
    end.to change { installment.reload.customer_count }.from(4).to(6)
  end

  it "does not SELECT installments to drop engagement cache" do
    allow(Installment).to receive(:find).and_call_original
    Rails.cache.write(installment.key_for_cache(:unique_open_count), 0)
    Rails.cache.write(installment.key_for_cache(:unique_open_count, dynamodb_reads: false), 0)

    Installment.invalidate_engagement_cache(installment.id, :unique_open_count)

    expect(Installment).not_to have_received(:find)
    expect(Rails.cache.read(installment.key_for_cache(:unique_open_count))).to be_nil
    expect(Rails.cache.read(installment.key_for_cache(:unique_open_count, dynamodb_reads: false))).to be_nil
  end
end
