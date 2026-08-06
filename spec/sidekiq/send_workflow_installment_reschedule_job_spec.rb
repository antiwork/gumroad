# frozen_string_literal: true

describe SendWorkflowInstallmentRescheduleJob do
  it "delegates the reschedule arguments to the delivery worker" do
    delivery_worker = instance_double(SendWorkflowInstallmentWorker)
    allow(SendWorkflowInstallmentWorker).to receive(:new).and_return(delivery_worker)
    expect(delivery_worker).to receive(:perform).with(1, 2, 3, nil, nil, nil, "2026-08-06T12:00:00Z")

    described_class.new.perform(1, 2, 3, nil, nil, nil, "2026-08-06T12:00:00Z")
  end
end
