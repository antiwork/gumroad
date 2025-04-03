# frozen_string_literal: true

# Public: Helper functions for working with the built in REXML parser.
module XmlHelpers
  # Public: Gets the text contained within the element at the given
  # xpath, and given a root element. The root element may be any
  # XML element and does not need to be the root of the document as
  # a whole.
  #
  # XPATH is formatted e.g. root/elemenetgroup/element
  #
  # Returns: A string containing the text content of the element at
  # the xpath, or nil if the element cannot be found.
  def self.text_at_xpath(root, xpath)
    element = root.elements.each(xpath) { }.first
    element&.text
  end
end
