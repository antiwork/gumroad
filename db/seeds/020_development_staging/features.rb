# frozen_string_literal: true

features_to_activate = []

features_to_activate.each do |feature|
  Feature.activate(feature)
end
