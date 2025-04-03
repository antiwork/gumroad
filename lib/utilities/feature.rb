# frozen_string_literal: true

module Feature
  extend self

  def activate(feature_name)
    Flipper.enable(feature_name)
  end

  def activate_user(feature_name, user)
    Flipper.enable_actor(feature_name, user)
  end

  def deactivate(feature_name)
    Flipper.disable(feature_name)
  end

  def deactivate_user(feature_name, user)
    Flipper.disable_actor(feature_name, user)
  end

  def activate_percentage(feature_name, percentage)
    Flipper.enable_percentage_of_actors(feature_name, percentage)
  end

  def deactivate_percentage(feature_name)
    Flipper.disable_percentage_of_actors(feature_name)
  end

  def active?(feature_name, actor = nil)
    Flipper.enabled?(feature_name, actor)
  end

  def inactive?(feature_name, actor = nil)
    !Flipper.enabled?(feature_name, actor)
  end
end
