# frozen_string_literal: true

require "test_helper"

class LlmsControllerTest < ActionController::TestCase
  tests LlmsController

  test "GET index renders llms.txt" do
    get :index, format: :txt

    assert_response :success
    assert_includes response.body, "# Gumroad"
  end

  test "llms.txt follows the llms.txt spec format" do
    get :index, format: :txt

    assert_match(/\A# Gumroad\n\n> /, response.body)
    assert_includes response.body, "## URL patterns"
    assert_includes response.body, "## API"
  end

  test "llms.txt documents canonical URL patterns and API docs" do
    get :index, format: :txt

    assert_includes response.body, "gumroad.com/l/{permalink}"
    assert_includes response.body, "{username}.gumroad.com"
    assert_includes response.body, "gumroad.com/discover"
    assert_includes response.body, "gumroad.com/wishlists/{slug}"
    assert_includes response.body, "https://gumroad.com/api"
    assert_includes response.body, "https://help.gumroad.com"
  end
end
