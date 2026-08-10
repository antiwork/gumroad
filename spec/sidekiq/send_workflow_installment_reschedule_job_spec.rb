# frozen_string_literal: true

describe SendWorkflowInstallmentRescheduleJob do
  it "delegates the reschedule arguments to the delivery worker" do
    delivery_worker = instance_double(SendWorkflowInstallmentWorker)
    allow(SendWorkflowInstallmentWorker).to receive(:new).and_return(delivery_worker)
    expect(delivery_worker).to receive(:perform).with(1, 2, 3, nil, nil, nil, "2026-08-06T12:00:00Z")

    described_class.new.perform(1, 2, 3, nil, nil, nil, "2026-08-06T12:00:00Z")
  end

  it "delegates a subscription reschedule" do
    delivery_worker = instance_double(SendWorkflowInstallmentWorker)
    allow(SendWorkflowInstallmentWorker).to receive(:new).and_return(delivery_worker)
    expect(delivery_worker).to receive(:perform).with(1, 2, nil, nil, nil, 3, "2026-08-06T12:00:00Z")

    described_class.new.perform(1, 2, nil, nil, nil, 3, "2026-08-06T12:00:00Z")
  end

  it "delegates follower and affiliate reschedules" do
    delivery_worker = instance_double(SendWorkflowInstallmentWorker)
    allow(SendWorkflowInstallmentWorker).to receive(:new).and_return(delivery_worker)
    expect(delivery_worker).to receive(:perform).with(1, 2, nil, 3, nil, nil, "2026-08-06T12:00:00Z")
    expect(delivery_worker).to receive(:perform).with(1, 2, nil, nil, 3, nil, "2026-08-06T12:00:00Z")

    described_class.new.perform(1, 2, nil, 3, nil, nil, "2026-08-06T12:00:00Z")
    described_class.new.perform(1, 2, nil, nil, 3, nil, "2026-08-06T12:00:00Z")
  end

  it "rejects ambiguous recipient combinations" do
    expect(SendWorkflowInstallmentWorker).not_to receive(:new)

    described_class.new.perform(1, 2, 3, 4, nil, nil, "2026-08-06T12:00:00Z")
    described_class.new.perform(1, 2, 3, nil, nil, 4, "2026-08-06T12:00:00Z")
  end

  it "does not suppress duplicate recovery jobs" do
    arguments = [1, 2, 3, nil, nil, nil, "2026-08-06T12:00:00Z"]
    delivery_time = 1.day.from_now

    job_ids = 2.times.map { described_class.perform_at(delivery_time, *arguments) }

    expect(job_ids).to all(be_present)
    expect(described_class.jobs.size).to eq(2)
  end
end
