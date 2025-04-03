# frozen_string_literal: true

# Helper methods for the "i want this!" container on product and profile pages
module ProductWantThisHelpers
  # in case of a single-tier / single-version-option products, recurrences will be shown as option boxes
  def select_recurrence_box(recurrence)
    find(".recurrence-boxes .variant-holder__variant-option", text: recurrence).click
  end
end
