# frozen_string_literal: true

IOS_APP_ID            = GlobalConfig.get("IOS_APP_ID", "916819108")
IOS_APP_STORE_URL     = "https://itunes.apple.com/app/id#{IOS_APP_ID}"
ANDROID_BUNDLE_ID     = GlobalConfig.get("ANDROID_BUNDLE_ID", "com.gumroad.app")
ANDROID_APP_STORE_URL = "https://play.google.com/store/apps/details?id=#{ANDROID_BUNDLE_ID}"
