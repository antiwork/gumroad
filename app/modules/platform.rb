# frozen_string_literal: true

module Platform
  WEB = "web"
  IPHONE = "iphone"
  ANDROID = "android"
  OTHER = "other"

  def self.all
    [
      WEB,
      IPHONE,
      ANDROID,
      OTHER
    ]
  end

  def self.all_mobile
    [
      IPHONE,
      ANDROID
    ]
  end
end
