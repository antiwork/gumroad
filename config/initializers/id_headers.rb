# frozen_string_literal: true

if Rails.env.staging? || Rails.env.production?
  REVISION = ENV.fetch("REVISION")
else
  REVISION = GlobalConfig.get("REVISION_DEFAULT", "no-revision")
end

GR_NUM = if Rails.env.production?
  GlobalConfig.get("ENV_IDENTIFIER_PROD", "PROD")
else
  GlobalConfig.get("ENV_IDENTIFIER_DEV", "DEV")
end
