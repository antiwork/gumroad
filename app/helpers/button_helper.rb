# frozen_string_literal: true

module ButtonHelper
  # color options: "success" | "warning" | "info" | "danger" | "primary" | "accent" | "filled"
  def navigation_button(body, url, options = {})
    disabled = options.delete(:disabled)
    color = options.delete(:color) || "accent"
    class_names = options.delete(:class)&.split(" ") || []
    class_names += ["button", color]

    link_to(body, url, **options.merge(class: class_names, inert: disabled))
  end
end
