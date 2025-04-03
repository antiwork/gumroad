# frozen_string_literal: true

require "spec_helper"

describe SidekiqUtility do
  before do
    ENV["SIDEKIQ_GRACEFUL_SHUTDOWN_TIMEOUT"] = "3"
    ENV["SIDEKIQ_LIFECYCLE_HOOK_NAME"] = "sample_hook_name"
    ENV["SIDEKIQ_ASG_NAME"] = "sample_asg_name"

    uri_double = double("uri_double")
    allow(URI).to receive(:parse).with(described_class::INSTANCE_ID_ENDPOINT).and_return(uri_double)
    allow(Net::HTTP).to receive(:get).with(uri_double).and_return("sample_instance_id")

    @aws_instance_profile_double = double("aws_instance_profile_double")
    allow(Aws::InstanceProfileCredentials).to receive(:new).and_return(@aws_instance_profile_double)
    @asg_double = double("asg_double")
    allow(Aws::AutoScaling::Client).to receive(:new).with(credentials: @aws_instance_profile_double).and_return(@asg_double)

    @current_time = Time.current
    travel_to(@current_time) do
      @sidekiq_utility = described_class.new
    end
  end

  after do
    ENV.delete("SIDEKIQ_GRACEFUL_SHUTDOWN_TIMEOUT")
    ENV.delete("SIDEKIQ_LIFECYCLE_HOOK_NAME")
    ENV.delete("SIDEKIQ_ASG_NAME")
  end

  describe "#initialize" do
    it "returns SidekiqUtility object with process_set and timeout_at variables" do
      expect(@sidekiq_utility.instance_variable_get(:@process_set).class).to eq Sidekiq::ProcessSet
      expect(@sidekiq_utility.instance_variable_get(:@timeout_at).to_i).to eq (@current_time + 3.hours).to_i
    end
  end

  describe "#instance_id" do
    it "returns the instance_id" do
      expect(@sidekiq_utility.send(:instance_id)).to eq "sample_instance_id"
    end
  end

  describe "#lifecycle_params" do
    it "returns lifecycle_params hash" do
      lifecycle_params = {
        lifecycle_hook_name: "sample_hook_name",
        auto_scaling_group_name: "sample_asg_name",
        instance_id: "sample_instance_id",
      }

      expect(@sidekiq_utility.send(:lifecycle_params)).to eq lifecycle_params
    end
  end

  describe "#hostname" do
    it "returns hostname of the server" do
      expect(@sidekiq_utility.send(:hostname)).to eq Socket.gethostname
    end
  end

  describe "#asg_client" do
    it "returns AWS Auto Scaling Group instance" do
      expect(Aws::AutoScaling::Client).to receive(:new).with(credentials: @aws_instance_profile_double)

      @sidekiq_utility.send(:asg_client)
    end
  end

  describe "sidekiq_process" do
    before do
      process_set = [
        { "hostname" => "test1", },
        { "hostname" => "test2" }
      ]

      allow(@sidekiq_utility).to receive(:hostname).and_return("test1")
      @sidekiq_utility.instance_variable_set(:@process_set, process_set)
    end

    it "returns the sidekiq process" do
      expect(@sidekiq_utility.send(:sidekiq_process)["hostname"]).to eq "test1"
    end
  end

  describe "proceed_with_instance_termination" do
    it "completes lifecycle ation" do
      params = @sidekiq_utility.send(:lifecycle_params).merge(lifecycle_action_result: "CONTINUE")
      expect(@asg_double).to receive(:complete_lifecycle_action).with(params)

      @sidekiq_utility.send(:proceed_with_instance_termination)
    end
  end

  describe "#timeout_exceeded?" do
    it "returns true if timeout is exceeded" do
      @sidekiq_utility.instance_variable_set(:@timeout_at, @current_time - 1.hour)

      expect(@sidekiq_utility.send(:timeout_exceeded?)).to be_truthy
    end
  end

  describe "#wait_for_sidekiq_to_process_existing_jobs" do
    before do
      allow(@sidekiq_utility).to receive(:sidekiq_process).and_return({ "busy" => 2, "identity" => "test_identity" })
    end

    context "when timeout is exceeded" do
      before do
        allow(@sidekiq_utility).to receive(:timeout_exceeded?).and_return(true)
      end

      it "doesn't record the lifecycle heartbeat" do
        expect(@asg_double).not_to receive(:record_lifecycle_action_heartbeat)

        @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
      end
    end

    context "when timeout is not exceeded" do
      before do
        allow_any_instance_of(described_class).to receive(:sleep) # Don't sleep!
        allow(@sidekiq_utility).to receive(:timeout_exceeded?).and_return(false, false, true) # Return different values per invocation
      end

      it "records the lifecycle heartbeat until the timeout exceeds" do
        expect(@asg_double).to receive(:record_lifecycle_action_heartbeat).twice

        @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
      end
    end

    context "when all jobs in the worker belong to ignored classes" do
      before do
        workers = [
          ["test_identity", "worker1", { "payload" => { "class" => "HandleSendgridEventJob" }.to_json }],
          ["test_identity", "worker1", { "payload" => { "class" => "SaveToMongoWorker" }.to_json }]
        ]
        allow(Sidekiq::Workers).to receive(:new).and_return(workers)
        allow(Rails.logger).to receive(:info)
      end

      it "logs the stuck jobs and breaks the loop" do
        expect(Rails.logger).to receive(:info).with("[SidekiqUtility] HandleSendgridEventJob, SaveToMongoWorker jobs are stuck. Proceeding with instance termination.")
        expect(@asg_double).not_to receive(:record_lifecycle_action_heartbeat)

        @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
      end
    end

    context "when not all jobs in the worker belong to ignored classes" do
      before do
        workers = [
          ["test_identity", "worker1", { "payload" => { "class" => "HandleSendgridEventJob" }.to_json }],
          ["test_identity", "worker1", { "payload" => { "class" => "OtherJob" }.to_json }]
        ]
        allow(Sidekiq::Workers).to receive(:new).and_return(workers)
        allow(@sidekiq_utility).to receive(:timeout_exceeded?).and_return(false, true)
      end

      it "continues the loop and records the lifecycle heartbeat" do
        expect(Rails.logger).not_to receive(:info).with("[SidekiqUtility] HandleSendgridEventJob, SaveToMongoWorker jobs are stuck. Proceeding with instance termination.")
        expect(@asg_double).to receive(:record_lifecycle_action_heartbeat).once

        @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
      end
    end
  end

  describe "#stop_process" do
    before do
      @sidekiq_process_double = double("sidekiq process double")
      allow(@sidekiq_utility).to receive(:sidekiq_process).and_return(@sidekiq_process_double)
      allow(@sidekiq_process_double).to receive(:quiet!)
      allow(@sidekiq_utility).to receive(:wait_for_sidekiq_to_process_existing_jobs)
      allow(@sidekiq_utility).to receive(:proceed_with_instance_termination)
    end

    after do
      @sidekiq_utility.stop_process
    end

    it "sets the process to quiet mode" do
      expect(@sidekiq_process_double).to receive(:quiet!)
    end

    it "waits for existing jobs to complete" do
      expect(@sidekiq_utility).to receive(:wait_for_sidekiq_to_process_existing_jobs)
    end

    it "proceeds with instance termination" do
      expect(@sidekiq_utility).to receive(:proceed_with_instance_termination)
    end
  end
end
