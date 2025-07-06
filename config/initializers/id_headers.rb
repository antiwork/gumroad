# frozen_string_literal: true

REVISION = if Rails.env.staging? || Rails.env.production?
  ENV.fetch("REVISION")
else
  GlobalConfig.get("REVISION_DEFAULT", "no-revision")
end

GR_NUM = if Rails.env.production?
  GlobalConfig.get("ENV_IDENTIFIER_PROD", "PROD")
else
  GlobalConfig.get("ENV_IDENTIFIER_DEV", "DEV")
end
