# frozen_string_literal: true

IOS_APP_ID            = GlobalConfig.get("IOS_APP_ID", "916819108")
IOS_BUNDLE_ID         = GlobalConfig.get("IOS_BUNDLE_ID", "com.GRD.Gumroad")
IOS_APP_STORE_URL     = "https://itunes.apple.com/app/id#{IOS_APP_ID}"
ANDROID_BUNDLE_ID     = GlobalConfig.get("ANDROID_BUNDLE_ID", "com.gumroad.app")
ANDROID_DEVELOPER_ID  = GlobalConfig.get("ANDROID_DEVELOPER_ID", "5700740786874955829")
ANDROID_APP_STORE_URL = "https://play.google.com/store/apps/details?id=#{ANDROID_BUNDLE_ID}"

if Rails.env.production?
  APP_STORE_API_ENDPOINT = GlobalConfig.get("APP_STORE_API_ENDPOINT", "https://api.storekit.itunes.apple.com")
else
  APP_STORE_API_ENDPOINT = GlobalConfig.get("APP_STORE_API_ENDPOINT", "https://api.storekit-sandbox.itunes.apple.com")
end

APP_STORE_CONNECT_API_ENDPOINT = GlobalConfig.get("APP_STORE_CONNECT_API_ENDPOINT", "https://api.appstoreconnect.apple.com")
