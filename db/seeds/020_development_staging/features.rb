# frozen_string_literal: true

features_to_activate = [
  :dashboard_spa_enabled
]

features_to_activate.each do |feature|
  Feature.activate(feature)
end
