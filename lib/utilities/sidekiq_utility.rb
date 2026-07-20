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

        ignored_classes = ["HandleSendgridEventJob"]

        if workers.any? && workers.all? { |_, _, work| ignored_classes.include?(JSON.parse(work["payload"])["class"]) }
          Rails.logger.info("[SidekiqUtility] #{ignored_classes.join(", ")} jobs are stuck. Proceeding with instance termination.")
          break
        end

        begin
          asg_client.record_lifecycle_action_heartbeat(lifecycle_params)
        rescue Aws::AutoScaling::Errors::ValidationError => e
          # The lifecycle action disappears when its heartbeat timeout expires
          # (AWS then proceeds with termination on its own) or when it was
          # already completed. There is nothing left to keep alive, so stop
          # waiting and move on to termination.
          raise unless e.message.include?("No active Lifecycle Action found")

          Rails.logger.info("[SidekiqUtility] Lifecycle action no longer active while sending heartbeat. Proceeding with instance termination. (#{e.message})")
          break
        end
        sleep 60
      end
    end

    def timeout_exceeded?
      Time.current > @timeout_at
    end

    def proceed_with_instance_termination
      asg_client.complete_lifecycle_action(lifecycle_params.merge(lifecycle_action_result: "CONTINUE"))
    rescue Aws::AutoScaling::Errors::ValidationError => e
      # If the lifecycle action already completed or its heartbeat timeout
      # expired, AWS has moved on and the instance is terminating anyway —
      # the outcome we wanted. Any other validation error (for example a
      # misconfigured hook or auto scaling group name) should still raise.
      raise unless e.message.include?("No active Lifecycle Action found")

      Rails.logger.info("[SidekiqUtility] Lifecycle action already completed or expired; nothing to do. (#{e.message})")
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
