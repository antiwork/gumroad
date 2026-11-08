# frozen_string_literal: true

class PublishSchedulePresenter
  def initialize(schedule)
    @schedule = schedule
  end

  def props
    return nil if @schedule.nil?

    {
      status: @schedule.status,
      publish_at: @schedule.publish_at.iso8601,
      local_time: @schedule.local_input_value,
      time_zone: @schedule.product.user.timezone,
      label: @schedule.local_time_label,
      failure_message: (@schedule.failure_message if @schedule.status == "failed" && @schedule.failure_dismissed_at.nil?),
    }
  end

  def self.editor_props(product)
    {
      publish_schedule: new(product.publish_schedule).props,
      can_create_publish_schedule: product.draft? && product.first_published_at.nil? && ProductPublishSchedule.creation_enabled_for?(product.user),
    }
  end
end
