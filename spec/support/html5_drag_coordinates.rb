# frozen_string_literal: true

require "capybara"
require "capybara/selenium/driver"

# Capybara's HTML5 drag emulation dispatches the initial dragenter without
# coordinates, so it lands at clientX/clientY (0, 0). SortableJS handles
# dragenter with the same logic as dragover and reads (0, 0) as "pointer above
# the list", moving the dragged row to the top; the follow-up dragover at the
# target's center then swaps it back, making upward drag_to reorders no-op.
# Dispatch dragenter at the same entry point as the first dragover instead.
module CapybaraHtml5DragCoordinates
  ORIGINAL_DRAGENTER = "  var dragEnterEvent = new DragEvent('dragenter', opts);\n"
  DRAGENTER_WITH_COORDINATES = "  var entryPoint = pointOnRect(sourceCenter, targetRect);\n" \
                               "  var dragEnterEvent = new DragEvent('dragenter', Object.assign({clientX: entryPoint.x, clientY: entryPoint.y}, opts));\n"

  drag_module = Capybara::Selenium::Node::Html5Drag
  script = drag_module::HTML5_DRAG_DROP_SCRIPT
  raise "Capybara's HTML5_DRAG_DROP_SCRIPT changed; update #{__FILE__}" unless script.include?(ORIGINAL_DRAGENTER)

  drag_module.send(:remove_const, :HTML5_DRAG_DROP_SCRIPT)
  drag_module.const_set(:HTML5_DRAG_DROP_SCRIPT, script.sub(ORIGINAL_DRAGENTER, DRAGENTER_WITH_COORDINATES).freeze)
end
