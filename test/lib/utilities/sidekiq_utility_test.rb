# frozen_string_literal: true

require "test_helper"

# Ported from spec/lib/utilities/sidekiq_utility_spec.rb (#5801).
#
# SidekiqUtility coordinates graceful worker shutdown with the Auto Scaling
# lifecycle hook. These tests keep the AWS and Sidekiq boundaries stubbed so
# they exercise the shutdown decisions without waiting or contacting either
# service.
class SidekiqUtilityTest < ActiveSupport::TestCase
  setup do
    ENV["SIDEKIQ_GRACEFUL_SHUTDOWN_TIMEOUT"] = "3"
    ENV["SIDEKIQ_LIFECYCLE_HOOK_NAME"] = "sample_hook_name"
    ENV["SIDEKIQ_ASG_NAME"] = "sample_asg_name"

    @uri_double = stub("uri_double")
    URI.stubs(:parse).with(SidekiqUtility::INSTANCE_ID_ENDPOINT).returns(@uri_double)
    Net::HTTP.stubs(:get).with(@uri_double).returns("sample_instance_id")

    @aws_instance_profile_double = stub("aws_instance_profile_double")
    Aws::InstanceProfileCredentials.stubs(:new).returns(@aws_instance_profile_double)
    @asg_double = stub("asg_double")
    Aws::AutoScaling::Client.stubs(:new).with(credentials: @aws_instance_profile_double).returns(@asg_double)

    @current_time = Time.current
    travel_to(@current_time) { @sidekiq_utility = SidekiqUtility.new }
  end

  teardown do
    ENV.delete("SIDEKIQ_GRACEFUL_SHUTDOWN_TIMEOUT")
    ENV.delete("SIDEKIQ_LIFECYCLE_HOOK_NAME")
    ENV.delete("SIDEKIQ_ASG_NAME")
  end

  test "initializes a process set and graceful shutdown deadline" do
    assert_instance_of Sidekiq::ProcessSet, @sidekiq_utility.instance_variable_get(:@process_set)
    assert_equal (@current_time + 3.hours).to_i, @sidekiq_utility.instance_variable_get(:@timeout_at).to_i
  end

  test "reads the instance id from the metadata endpoint" do
    assert_equal "sample_instance_id", @sidekiq_utility.send(:instance_id)
  end

  test "builds lifecycle parameters" do
    assert_equal(
      {
        lifecycle_hook_name: "sample_hook_name",
        auto_scaling_group_name: "sample_asg_name",
        instance_id: "sample_instance_id",
      },
      @sidekiq_utility.send(:lifecycle_params),
    )
  end

  test "returns the server hostname" do
    assert_equal Socket.gethostname, @sidekiq_utility.send(:hostname)
  end

  test "finds every process labeled with this instance" do
    process_set = [
      { "hostname" => "worker-1", "labels" => ["instance:sample_instance_id"] },
      { "hostname" => "worker-2", "labels" => ["instance:sample_instance_id"] },
      { "hostname" => "worker-3", "labels" => ["instance:other_instance_id"] },
    ]
    @sidekiq_utility.instance_variable_set(:@process_set, process_set)

    assert_equal ["worker-1", "worker-2"], @sidekiq_utility.send(:instance_processes).map { |process| process["hostname"] }
  end

  test "falls back to the current hostname when no process carries the instance label" do
    process_set = [{ "hostname" => "test1", "labels" => [] }, { "hostname" => "test2" }]
    @sidekiq_utility.stubs(:hostname).returns("test1")
    @sidekiq_utility.instance_variable_set(:@process_set, process_set)

    assert_equal ["test1"], @sidekiq_utility.send(:instance_processes).map { |process| process["hostname"] }
  end

  test "creates an AWS Auto Scaling client with instance credentials" do
    Aws::AutoScaling::Client.expects(:new).with(credentials: @aws_instance_profile_double).returns(@asg_double)

    assert_same @asg_double, @sidekiq_utility.send(:asg_client)
  end

  test "completes the lifecycle action" do
    params = @sidekiq_utility.send(:lifecycle_params).merge(lifecycle_action_result: "CONTINUE")
    @asg_double.expects(:complete_lifecycle_action).with(params)

    @sidekiq_utility.send(:proceed_with_instance_termination)
  end

  test "does not raise when the lifecycle action is already inactive" do
    error = Aws::AutoScaling::Errors::ValidationError.new(nil, "No active Lifecycle Action found with instance ID i-abc123 and HookName sample_hook_name")
    @asg_double.stubs(:complete_lifecycle_action).raises(error)
    Rails.logger.expects(:info).with(regexp_matches(/Lifecycle action already completed or expired/))

    @sidekiq_utility.send(:proceed_with_instance_termination)
  end

  test "re-raises unrelated lifecycle validation errors" do
    error = Aws::AutoScaling::Errors::ValidationError.new(nil, "1 validation error detected: Value at 'lifecycleHookName' failed to satisfy constraint")
    @asg_double.stubs(:complete_lifecycle_action).raises(error)

    assert_raises(Aws::AutoScaling::Errors::ValidationError) do
      @sidekiq_utility.send(:proceed_with_instance_termination)
    end
  end

  test "reports when the graceful shutdown deadline has passed" do
    @sidekiq_utility.instance_variable_set(:@timeout_at, @current_time - 1.hour)

    assert @sidekiq_utility.send(:timeout_exceeded?)
  end

  test "does not heartbeat after the graceful shutdown deadline" do
    @sidekiq_utility.stubs(:instance_processes).returns([{ "busy" => 2, "identity" => "test_identity" }])
    @sidekiq_utility.stubs(:timeout_exceeded?).returns(true)
    @asg_double.expects(:record_lifecycle_action_heartbeat).never

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  # The worker stays busy for every check, so the only thing that can end the
  # loop is the deadline. Returning false twice then true is what proves two
  # heartbeats happen before the deadline stops the wait: if the loop exited
  # because the worker went idle instead, this would still pass while covering
  # a different branch.
  test "heartbeats until the graceful shutdown deadline is reached" do
    @sidekiq_utility.stubs(:instance_processes).returns([{ "busy" => 2, "identity" => "test_identity" }])
    @sidekiq_utility.stubs(:timeout_exceeded?).returns(false, false, true)
    @sidekiq_utility.stubs(:sleep)
    @asg_double.expects(:record_lifecycle_action_heartbeat).twice

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "stops waiting when every running job is a stuck SendGrid event job" do
    @sidekiq_utility.stubs(:instance_processes).returns([{ "busy" => 1, "identity" => "test_identity" }])
    Sidekiq::Workers.stubs(:new).returns([
                                           ["test_identity", "worker1", { "payload" => { "class" => "HandleSendgridEventJob" }.to_json }],
                                         ])
    Rails.logger.expects(:info).with("[SidekiqUtility] HandleSendgridEventJob jobs are stuck. Proceeding with instance termination.")
    @asg_double.expects(:record_lifecycle_action_heartbeat).never

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "stops waiting when the lifecycle heartbeat reports an inactive action" do
    @sidekiq_utility.stubs(:instance_processes).returns([{ "busy" => 1, "identity" => "test_identity" }])
    @sidekiq_utility.stubs(:timeout_exceeded?).returns(false)
    Sidekiq::Workers.stubs(:new).returns([])
    error = Aws::AutoScaling::Errors::ValidationError.new(nil, "No active Lifecycle Action found")
    @asg_double.expects(:record_lifecycle_action_heartbeat).raises(error)
    Rails.logger.expects(:info).with(regexp_matches(/Lifecycle action no longer active while sending heartbeat/))

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "continues heartbeating when another job is still running" do
    @sidekiq_utility.stubs(:instance_processes).returns(
      [{ "busy" => 2, "identity" => "test_identity" }],
      [{ "busy" => 1, "identity" => "test_identity" }],
    )
    @sidekiq_utility.stubs(:timeout_exceeded?).returns(false, true)
    @sidekiq_utility.stubs(:sleep)
    Sidekiq::Workers.stubs(:new).returns([
                                           ["test_identity", "worker1", { "payload" => { "class" => "HandleSendgridEventJob" }.to_json }],
                                           ["test_identity", "worker1", { "payload" => { "class" => "OtherJob" }.to_json }],
                                         ])
    @asg_double.expects(:record_lifecycle_action_heartbeat).once
    Rails.logger.expects(:info).with(regexp_matches(/HandleSendgridEventJob jobs are stuck/)).never

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "stops waiting once every process on the instance is idle" do
    @sidekiq_utility.stubs(:instance_processes).returns([{ "busy" => 0, "identity" => "a" }, { "busy" => 0, "identity" => "b" }])
    @asg_double.expects(:record_lifecycle_action_heartbeat).never

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "keeps waiting while any process on the instance is busy" do
    @sidekiq_utility.stubs(:instance_processes).returns(
      [{ "busy" => 0, "identity" => "a" }, { "busy" => 1, "identity" => "b" }],
      [{ "busy" => 0, "identity" => "a" }, { "busy" => 0, "identity" => "b" }],
    )
    @sidekiq_utility.stubs(:timeout_exceeded?).returns(false)
    @sidekiq_utility.stubs(:sleep)
    Sidekiq::Workers.stubs(:new).returns([["b", "worker1", { "payload" => { "class" => "OtherJob" }.to_json }]])
    @asg_double.expects(:record_lifecycle_action_heartbeat).once

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "ignores stuck SendGrid jobs only when every busy job on the instance is one" do
    @sidekiq_utility.stubs(:instance_processes).returns([{ "busy" => 1, "identity" => "a" }, { "busy" => 1, "identity" => "b" }])
    Sidekiq::Workers.stubs(:new).returns([
                                           ["a", "worker1", { "payload" => { "class" => "HandleSendgridEventJob" }.to_json }],
                                           ["b", "worker1", { "payload" => { "class" => "HandleSendgridEventJob" }.to_json }],
                                           ["elsewhere", "worker1", { "payload" => { "class" => "OtherJob" }.to_json }],
                                         ])
    Rails.logger.expects(:info).with("[SidekiqUtility] HandleSendgridEventJob jobs are stuck. Proceeding with instance termination.")
    @asg_double.expects(:record_lifecycle_action_heartbeat).never

    @sidekiq_utility.send(:wait_for_sidekiq_to_process_existing_jobs)
  end

  test "sets every process on the instance to quiet mode" do
    prepare_stop_process
    second_process = stub("second_sidekiq_process")
    second_process.expects(:quiet!)
    @sidekiq_utility.stubs(:instance_processes).returns([@sidekiq_process_double, second_process])
    @sidekiq_process_double.expects(:quiet!)

    @sidekiq_utility.stop_process
  end

  test "warns and proceeds with termination when no process belongs to the instance" do
    prepare_stop_process
    @sidekiq_utility.stubs(:instance_processes).returns([])
    @sidekiq_utility.stubs(:hostname).returns("test1")
    Rails.logger.expects(:warn).with("[SidekiqUtility] No Sidekiq process found for instance sample_instance_id or hostname test1. Proceeding with instance termination.")
    @sidekiq_utility.expects(:proceed_with_instance_termination)

    @sidekiq_utility.stop_process
  end

  test "waits for existing jobs to complete" do
    prepare_stop_process
    @sidekiq_utility.expects(:wait_for_sidekiq_to_process_existing_jobs)

    @sidekiq_utility.stop_process
  end

  test "proceeds with instance termination" do
    prepare_stop_process
    @sidekiq_utility.expects(:proceed_with_instance_termination)

    @sidekiq_utility.stop_process
  end

  private
    def prepare_stop_process
      process_double = stub("sidekiq_process", quiet!: nil)
      @sidekiq_process_double = process_double
      @sidekiq_utility.stubs(:instance_processes).returns([process_double])
      @sidekiq_utility.stubs(:wait_for_sidekiq_to_process_existing_jobs)
      @sidekiq_utility.stubs(:proceed_with_instance_termination)
    end
end
