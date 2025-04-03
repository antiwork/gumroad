# frozen_string_literal: true

module InfosHelper
  include ActionView::Helpers::TextHelper
  def duration_displayable(duration)
    return nil if !duration || duration == 0
    time = ""
    if duration < 60
      return time = (Time.mktime(0) + duration).strftime("0:%S")
    elsif duration < 60 * 10
      time = (Time.mktime(0) + duration).strftime("%M:%S")
      time.slice!(0) if time[0].chr == "0"
    else
      return (duration / 60).to_s + " " + "minutes"
    end

    time
  end

  def size_displayable
    ActionController::Base.helpers.number_to_human_size(size)
  end

  def bitrate_displayable
    "#{bitrate} kbps" if bitrate
  end

  def framerate_displayable
    "#{framerate} fps" if framerate
  end

  def pagelength_displayable
    return unless pagelength
    pluralize(pagelength, epub? ? "section" : "page")
  end

  def resolution_displayable
    if width == 1920 && height == 1080
      "1080p"
    elsif width == 1280 && height == 720
      "720p"
    elsif width == 854 && height == 480
      "480p"
    else
      "#{width} x #{height} px" if width && height
    end
  end
end
