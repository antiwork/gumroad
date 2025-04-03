# frozen_string_literal: true

# Usage:
#
# class Onetime::MyScript < Onetime::Base
#   def initialize(args)
#     @args = args
#   end
#
#   def process
#     Rails.logger.info "I do great things"
#   end
# end
#
# To execute without logging:
# Onetime::MyScript.new(args).process
# To execute with logging:
# Onetime::MyScript.new(args).process_with_logging
#
class Onetime::Base
  def process_with_logging(...)
    with_logging do
      process(...)
    end
  end

  private
    def with_logging
      custom_logger = enable_logger
      start_time = Time.current
      Rails.logger.info "Started process at #{start_time}"

      yield

      finish_time = Time.current
      Rails.logger.info "Finished process at #{finish_time} in #{ActiveSupport::Duration.build(finish_time - start_time).inspect}"
      close_logger(custom_logger)
    end

    def enable_logger
      custom_logger = Logger.new(
        "log/#{self.class.name.split('::').last.underscore}_#{Time.current.strftime('%Y-%m-%d_%H-%M-%S')}.log",
        level: Logger::INFO
      )
      Rails.logger.broadcast_to(custom_logger)
      custom_logger
    end

    def close_logger(custom_logger)
      Rails.logger.stop_broadcasting_to(custom_logger)
      custom_logger.close
    end

    def process
      raise NotImplementedError, "Subclasses must implement a process method"
    end
end
