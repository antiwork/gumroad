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
end
