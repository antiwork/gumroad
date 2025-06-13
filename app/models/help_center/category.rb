# frozen_string_literal: true

class HelpCenter::Category < ActiveYaml::Base
  include ActiveHash::Associations
  include ActiveHash::Enum

  set_root_path "app/models"

  has_many :articles, class_name: "HelpCenter::Article"

  enum_accessor :title

  def to_param
    slug
  end

  def categories_for_same_audience
    @_categories_for_same_audience ||= HelpCenter::Category.where(audience: audience)
  end
end
