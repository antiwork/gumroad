# frozen_string_literal: true

class PublishSchedulePresenter
  def initialize(schedule)
    @schedule = schedule
  end

  def props
    return nil if @schedule.nil? || @schedule.status == "published"

    { status: @schedule.status, label: @schedule.local_time_label, failure_message: @schedule.failure_message }
  end

  def self.editor_props(product)
    {
      publish_schedule: (new(product.publish_schedule).props if product.draft?),
      can_create_publish_schedule: product.draft? && product.first_published_at.nil? && ProductPublishSchedule.creation_enabled_for?(product.user),
    }
  end
end
