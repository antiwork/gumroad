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

  it "keeps an increment that lands mid-flush discoverable by the next flush" do
    installment.increment_total_delivered(by: 2)

    allow(Installment).to receive(:update_counters).and_wrap_original do |m, *args, **kwargs|
      installment.increment_total_delivered(by: 5)
      m.call(*args, **kwargs)
    end

    expect do
      described_class.new.perform
    end.to change { installment.reload.customer_count }.from(4).to(6)

    expect($redis.sismember(RedisKey.installment_delivered_delta_ids, installment.id)).to be(true)

    allow(Installment).to receive(:update_counters).and_call_original
    expect do
      described_class.new.perform
    end.to change { installment.reload.customer_count }.from(6).to(11)
    expect($redis.sismember(RedisKey.installment_delivered_delta_ids, installment.id)).to be(false)
  end

  it "retains the buffered delta when the customer_count update fails" do
    installment.increment_total_delivered(by: 3)

    allow(Installment).to receive(:update_counters).and_raise(ActiveRecord::StatementInvalid)
    expect do
      described_class.new.perform
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(installment.reload.customer_count).to eq(4)

    allow(Installment).to receive(:update_counters).and_call_original
    expect do
      described_class.new.perform
    end.to change { installment.reload.customer_count }.from(4).to(7)
  end

  it "does not write through when enqueueing the flush job fails" do
    allow(FlushInstallmentDeliveredDeltasJob).to receive(:perform_async).and_raise(Redis::BaseError)
    expect do
      installment.increment_total_delivered(by: 2)
    end.not_to change { installment.reload.customer_count }

    allow(FlushInstallmentDeliveredDeltasJob).to receive(:perform_async).and_call_original
    expect do
      described_class.new.perform
    end.to change { installment.reload.customer_count }.from(4).to(6)
  end

  it "does not re-apply a claimed delta on a second flush" do
    installment.increment_total_delivered(by: 2)
    described_class.new.perform
    expect(installment.reload.customer_count).to eq(6)

    expect do
      described_class.new.perform
    end.not_to change { installment.reload.customer_count }
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
