# frozen_string_literal: true

module IconHelper
  # For icon values see app/icons/images/icons folder
  #
  def icon(icon, options = {})
    css_classes = ["icon", "icon-#{icon}", options[:class]]
    tag.span(nil, **options.merge(class: css_classes))
  end

  def icon_yes
    icon("solid-check-circle", aria: { label: "Yes" }, class: "text-success")
  end

  def icon_no
    icon("x-circle-fill", aria: { label: "No" }, class: "text-danger")
  end
end
