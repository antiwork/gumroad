# frozen_string_literal: true

class SidekiqUtility
  INSTANCE_ID_ENDPOINT = "http://169.254.169.254/latest/meta-data/instance-id"

  def initialize
    @process_set = Sidekiq::ProcessSet.new

    graceful_shutdown_timeout = ENV.fetch("SIDEKIQ_GRACEFUL_SHUTDOWN_TIMEOUT", 4).to_i.hours
    @timeout_at = Time.current + graceful_shutdown_timeout
  end

  def stop_process
    # Set process to quiet mode.
    sidekiq_process.quiet!

    wait_for_sidekiq_to_process_existing_jobs

    proceed_with_instance_termination
  end

  private
    def wait_for_sidekiq_to_process_existing_jobs
      while sidekiq_process["busy"].nonzero? do
        # Break the loop and proceed with termination if waiting times out.
        break if timeout_exceeded?

        # Fix for stuck HandleSendgridEventJob jobs
        # TODO: Remove this once we fix the root cause of the stuck jobs
        workers = Sidekiq::Workers.new.select do |process_id, _, _|
          process_id == sidekiq_process["identity"]
        end

        ignored_classes = ["HandleSendgridEventJob", "SaveToMongoWorker"]

        if workers.any? && workers.all? { |_, _, work| ignored_classes.include?(JSON.parse(work["payload"])["class"]) }
          Rails.logger.info("[SidekiqUtility] #{ignored_classes.join(", ")} jobs are stuck. Proceeding with instance termination.")
          break
        end

        asg_client.record_lifecycle_action_heartbeat(lifecycle_params)
        sleep 60
      end
    end

    def timeout_exceeded?
      Time.current > @timeout_at
    end

    def proceed_with_instance_termination
      asg_client.complete_lifecycle_action(lifecycle_params.merge(lifecycle_action_result: "CONTINUE"))
    end

    def instance_id
      @_instance_id ||= Net::HTTP.get(URI.parse(INSTANCE_ID_ENDPOINT))
    end

    def hostname
      @_hostname ||= Socket.gethostname
    end

    def asg_client
      @_asg_client ||= begin
         aws_credentials = Aws::InstanceProfileCredentials.new
         Aws::AutoScaling::Client.new(credentials: aws_credentials)
       end
    end

    def sidekiq_process
      @process_set.find { |process| process["hostname"] == hostname }
    end

    def lifecycle_params
      {
        lifecycle_hook_name: ENV["SIDEKIQ_LIFECYCLE_HOOK_NAME"],
        auto_scaling_group_name: ENV["SIDEKIQ_ASG_NAME"],
        instance_id:,
      }
    end
end
