# frozen_string_literal: true

# Explicitly require the dependency HelpCenter::Category to avoid circular
# dependency that results in a deadlock during loading.
require "help_center/category"

class HelpCenter::Article < ActiveYaml::Base
  include ActiveHash::Associations

  set_root_path "app/models"

  belongs_to :category, class_name: "HelpCenter::Category"

  def to_param
    slug
  end

  def to_partial_path
    "help_center/articles/contents/#{slug}"
  end
end
