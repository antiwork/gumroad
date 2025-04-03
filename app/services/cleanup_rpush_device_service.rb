# frozen_string_literal: true

class CleanupRpushDeviceService
  def initialize(feedback)
    @feedback = feedback
  end

  def process
    Device.where(token: @feedback.device_token).destroy_all
    @feedback.destroy
  rescue => e
    Rails.logger.error "Could not clean up a device token based on APN feedback #{@feedback.inspect}: #{e.inspect}"
    Bugsnag.notify "Could not clean up a device token based on APN feedback #{@feedback.inspect}: #{e.inspect}"
  end
end
