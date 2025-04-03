# frozen_string_literal: true

class CommunityNotificationSettingPresenter
  def initialize(settings:)
    @settings = settings
  end

  def props
    { recap_frequency: settings.recap_frequency }
  end

  private
    attr_reader :settings
end
