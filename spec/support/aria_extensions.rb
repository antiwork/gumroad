# frozen_string_literal: true

Capybara.modify_selector(:button) do
  expression_filter(:role, default: true) do |xpath|
    xpath[XPath.attr(:role).equals("button").or ~XPath.attr(:role)]
  end
end

Capybara.modify_selector(:link) do
  expression_filter(:role, default: true) do |xpath|
    xpath[XPath.attr(:role).equals("link").or ~XPath.attr(:role)]
  end

  expression_filter(:inert, :boolean, default: false) do |xpath, disabled|
    xpath[disabled ? XPath.attr(:"inert") : (~XPath.attr(:"inert"))]
  end
end

# capybara_accessible_selectors does have an implementation for this, but it doesn't use XPath,
# so combining it into :command would be very difficult
Capybara.add_selector(:menuitem, locator_type: [String, Symbol]) do
  xpath do |locator, **options|
    xpath = XPath.descendant[XPath.attr(:role).equals("menuitem")]

    unless locator.nil?
      locator = locator.to_s
      matchers = [XPath.string.n.is(locator),
                  XPath.attr(:title).is(locator),
                  XPath.attr(:'aria-label').is(locator)]
      xpath = xpath[matchers.reduce(:|)]
    end

    xpath
  end

  expression_filter(:disabled, :boolean, default: false) do |xpath, disabled|
    xpath[disabled ? XPath.attr(:"inert") : (~XPath.attr(:"inert"))]
  end
end

Capybara.add_selector(:radio_button, locator_type: [String, Symbol]) do
  xpath do |locator, **options|
    xpath = XPath.descendant[[XPath.self(:input).attr(:type).is("radio"), XPath.attr(:role).one_of("radio", "menuitemradio")].reduce(:|)]
    xpath = locate_field(xpath, locator, **options)
    xpath += XPath.descendant[XPath.attr(:role).one_of("radio", "menuitemradio")][XPath.string.n.is(locator)] if locator
    xpath
  end

  filter_set(:_field, %i[name])

  node_filter(:disabled, :boolean) { |node, value| !(value ^ (node.disabled? || node["inert"] == "true")) }
  node_filter(:checked, :boolean) { |node, value| !(value ^ (node.checked? || node["aria-checked"] == "true")) }
  node_filter(:unchecked, :boolean) { |node, value| (value ^ (node.checked? || node["aria-checked"] == "true")) }

  node_filter(%i[option with]) do |node, value|
    val = node.value
    (value.is_a?(Regexp) ? value.match?(val) : val == value.to_s).tap do |res|
      add_error("Expected value to be #{value.inspect} but it was #{val.inspect}") unless res
    end
  end

  describe_node_filters do |option: nil, with: nil, **|
    desc = +""
    desc << " with value #{option.inspect}" if option
    desc << " with value #{with.inspect}" if with
    desc
  end
end

Capybara.add_selector(:tooltip, locator_type: [nil]) do
  xpath do |locator|
    # TODO: Remove once incorrect locator_type raises an error instead of just logging a warning
    raise "Tooltip does not support a locator, use the `text:` option instead" if locator.present?
    XPath.anywhere[XPath.attr(:role) == "tooltip"]
  end

  node_filter(:attached, default: true) do |node|
    node["id"] == (node.query_scope["aria-describedby"] || node.query_scope.ancestor("[aria-describedby]")["aria-describedby"])
  end
end

Capybara.add_selector(:status, locator_type: [nil]) do
  xpath do |locator|
    # TODO: Remove once incorrect locator_type raises an error instead of just logging a warning
    raise "Status does not support a locator, use the text: option" if locator.present?
    XPath.anywhere[XPath.attr(:role) == "status"]
  end
end

Capybara.add_selector(:command) do
  xpath do |locator, **options|
    %i[link button menuitem tab_button].map do |selector|
      expression_for(selector, locator, **options)
    end.reduce(:union)
  end
  node_filter(:disabled, :boolean, default: false, skip_if: :all) { |node, value| !(value ^ node.disabled?) }
  expression_filter(:disabled, :boolean, default: false, skip_if: :all) { |xpath, val| val ? xpath : xpath[~XPath.attr(:"inert")] }
  expression_filter(:role, default: true) do |xpath|
    xpath[XPath.attr(:role).one_of("button", "link", "menuitem", "tab").or ~XPath.attr(:role)]
  end
end

Capybara.add_selector(:combo_box_list_box, locator_type: Capybara::Node::Element) do
  xpath do |input|
    ids = (input[:"aria-owns"] || input[:"aria-controls"])&.split(/\s+/)&.compact

    raise Capybara::ElementNotFound, "listbox cannot be found without attributes aria-owns or aria-controls" if !ids || ids.empty?

    XPath.anywhere[[
      [XPath.attr(:role) == "listbox", XPath.self(:datalist)].reduce(:|),
      ids.map { |id| XPath.attr(:id) == id }.reduce(:|)
    ].reduce(:&)]
  end
end

Capybara.add_selector(:image, locator_type: [String, Symbol]) do
  xpath do |locator, src: nil|
    xpath = XPath.descendant(:img)
    xpath = xpath[XPath.attr(:alt).is(locator)] if locator
    xpath = xpath[XPath.attr(:src).is(src)] if src
    xpath
  end
end

Capybara.add_selector(:tablist, locator_type: [String, Symbol]) do
  xpath do |locator, **options|
    xpath = XPath.descendant[XPath.attr(:role) == "tablist"]
    xpath = xpath[XPath.attr(:"aria-label").is(locator)] if locator
    xpath
  end
end

Capybara.modify_selector(:tab_button) do
  xpath do |name|
    XPath.descendant[[
      XPath.attr(:role) == "tab",
      XPath.ancestor[XPath.attr(:role) == "tablist"],
      XPath.string.n.is(name.to_s) | XPath.attr(:"aria-label").is(name.to_s)
    ].reduce(:&)]
  end
end

Capybara.modify_selector(:table) do
  xpath do |locator|
    xpath = XPath.descendant(:table)
    xpath = xpath[
      XPath.attr(:"aria-label").is(locator) |
      XPath.child(:caption)[XPath.string.n.is(locator)]
    ] if locator
    xpath
  end
end

# support any element with `aria-role` - the default implementation enforces this to be an `input` element
# replace aria-disabled with inert
Capybara.modify_selector(:combo_box) do
  xpath do |locator, **options|
    xpath = XPath.descendant[XPath.attr(:role) == "combobox"]
    locate_field(xpath, locator, **options)
  end

  # with exact enabled options
  node_filter(:enabled_options) do |node, options|
    options = Array(options)
    actual = options_text(node, expression_for(:list_box_option, nil)) { |n| n["inert"] != "true" }
    match_all_options?(actual, options).tap do |res|
      add_error("Expected enabled options #{options.inspect} found #{actual.inspect}") unless res
    end
  end

  # with exact enabled options
  node_filter(:with_enabled_options) do |node, options|
    options = Array(options)
    actual = options_text(node, expression_for(:list_box_option, nil)) { |n| n["inert"] != "true" }
    match_some_options?(actual, options).tap do |res|
      add_error("Expected with at least enabled options #{options.inspect} found #{actual.inspect}") unless res
    end
  end

  # with exact disabled options
  node_filter(:disabled_options) do |node, options|
    options = Array(options)
    actual = options_text(node, expression_for(:list_box_option, nil)) { |n| n["inert"] == "true" }
    match_all_options?(actual, options).tap do |res|
      add_error("Expected disabled options #{options.inspect} found #{actual.inspect}") unless res
    end
  end

  # with exact enabled options
  node_filter(:with_disabled_options) do |node, options|
    options = Array(options)
    actual = options_text(node, expression_for(:list_box_option, nil)) { |n| n["inert"] == "true" }
    match_some_options?(actual, options).tap do |res|
      add_error("Expected with at least disabled options #{options.inspect} found #{actual.inspect}") unless res
    end
  end
end

# override table_row selector to support colspan
Capybara.modify_selector(:table_row) do
  def position(xpath)
    siblings = xpath.preceding_sibling
    siblings[XPath.attr(:colspan).inverse].count.plus(siblings.attr(:colspan).sum).plus(1)
  end
  xpath do |locator|
    xpath = XPath.descendant(:tr)
    if locator.is_a? Hash
      locator.reduce(xpath) do |xp, (header, cell)|
        header_xp = XPath.ancestor(:table)[1].descendant(:tr)[1].descendant(:th)[XPath.string.n.is(header)]
        cell_xp = XPath.descendant(:td)[
          XPath.string.n.is(cell) & position(XPath).equals(position(header_xp))
        ]
        xp.where(cell_xp)
      end
    elsif locator
      initial_td = XPath.descendant(:td)[XPath.string.n.is(locator.shift)]
      tds = locator.reverse.map { |cell| XPath.following_sibling(:td)[XPath.string.n.is(cell)] }
                   .reduce { |xp, cell| xp.where(cell) }
      xpath[initial_td[tds]]
    else
      xpath
    end
  end
end

# add matching by aria-label and handle disabled state
Capybara.modify_selector(:disclosure) do
  xpath do |name, **|
    match_name = XPath.string.n.is(name.to_s) | XPath.attr(:"aria-label").equals(name.to_s)
    button = (XPath.self(:button) | (XPath.attr(:role) == "button")) & match_name
    aria = XPath.descendant[XPath.attr(:id) == XPath.anywhere[button][XPath.attr(:"aria-expanded")].attr(:"aria-controls")]
    details = XPath.descendant(:details)[XPath.child(:summary)[match_name]]
    aria + details
  end
end

Capybara.modify_selector(:disclosure_button) do
  xpath do |name, **|
    match_name = XPath.string.n.is(name.to_s) | XPath.attr(:"aria-label").equals(name.to_s)
    XPath.descendant[[
      (XPath.self(:button) | (XPath.attr(:role) == "button")),
      XPath.attr(:"aria-expanded"),
      match_name
    ].reduce(:&)] + XPath.descendant(:summary)[match_name]
  end

  expression_filter(:disabled, :boolean, default: false) do |xpath, val|
    disabled = XPath.attr(:disabled) | XPath.attr(:inert)
    xpath[val ? disabled : ~disabled]
  end

  describe_expression_filters
end

module Capybara
  module Node
    module Actions
      def click_command(locator = nil, **options)
        find(:command, locator, **options).click
      end
      alias_method :click_on, :click_command
    end
  end

  module RSpecMatchers
    %i[tooltip radio_button command image tablist status table_row list_box_option].each do |selector|
      define_method "have_#{selector}" do |locator = nil, **options, &optional_filter_block|
        Matchers::HaveSelector.new(selector, locator, **options, &optional_filter_block)
      end
    end
  end
end

RSpec::Matchers.define :have_table_rows_in_order do |expected_rows|
  match do |actual|
    return false unless expected_rows.is_a?(Array) && expected_rows.any?

    all_table_rows = actual.all(:table_row)
    actual_row_positions = []

    expected_rows.each_with_index do |row_data, index|
      # `#find` fails the assertion if the row is not found, thus we do not
      # need to handle this error in our own `failure_message` implementation.
      found_row = actual.find(:table_row, row_data)

      actual_row_positions << all_table_rows.index(found_row)
    end

    actual_row_positions.each_index do |index|
      next if index == 0

      prev_position = actual_row_positions[index - 1]
      current_position = actual_row_positions[index]

      if current_position < prev_position
        @out_of_order_indices = [index - 1, index]
        return false
      end
    end

    true
  end

  failure_message do |actual|
    first_index, second_index = @out_of_order_indices
    first_row = expected_rows[first_index]
    second_row = expected_rows[second_index]

    <<~TEXT
      expected table rows to be in order, but row
        #{second_row.inspect}
      appeared before row
        #{first_row.inspect}
    TEXT
  end
end
