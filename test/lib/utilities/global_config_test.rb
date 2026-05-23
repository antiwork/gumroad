# frozen_string_literal: true

require "test_helper"

class GlobalConfigTest < ActiveSupport::TestCase
  def with_env(values)
    originals = values.to_h { |k, _| [k, ENV[k]] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "returns the value of the environment variable when set" do
    with_env("TEST_VAR" => "test_value") do
      assert_equal "test_value", GlobalConfig.get("TEST_VAR")
    end
  end

  test "returns the provided default when the environment variable is missing" do
    with_env("MISSING_VAR" => nil) do
      assert_equal "default", GlobalConfig.get("MISSING_VAR", "default")
    end
  end

  test "returns nil when no default is given and no credential is found" do
    with_env("MISSING_VAR" => nil) do
      GlobalConfig.stub :fetch_from_credentials, nil do
        assert_nil GlobalConfig.get("MISSING_VAR")
      end
    end
  end

  test "falls back to Rails credentials" do
    with_env("CREDENTIAL_KEY" => nil) do
      GlobalConfig.stub :fetch_from_credentials, "credential_value" do
        assert_equal "credential_value", GlobalConfig.get("CREDENTIAL_KEY")
      end
    end
  end

  test "falls back to Rails credentials for multi-level keys with __ separator" do
    with_env("HELLO_WORLD__FOO_BAR" => nil) do
      GlobalConfig.stub :fetch_from_credentials, "123" do
        assert_equal "123", GlobalConfig.get("HELLO_WORLD__FOO_BAR")
      end
    end
  end

  test "returns nil when the environment variable is empty" do
    with_env("EMPTY_VAR" => "") do
      GlobalConfig.stub :fetch_from_credentials, nil do
        assert_nil GlobalConfig.get("EMPTY_VAR")
      end
    end
  end

  test "returns nil when the environment variable is blank" do
    with_env("BLANK_VAR" => "   ") do
      GlobalConfig.stub :fetch_from_credentials, nil do
        assert_nil GlobalConfig.get("BLANK_VAR")
      end
    end
  end

  test "does not coerce blank values to nil when a default is provided" do
    with_env("BLANK_VAR" => "") do
      GlobalConfig.stub :fetch_from_credentials, nil do
        assert_equal "", GlobalConfig.get("BLANK_VAR", "default")
      end
    end
  end

  test "dig joins parts with double underscores and returns the value" do
    with_env("PART1__PART2__PART3" => "nested_value") do
      assert_equal "nested_value", GlobalConfig.dig("part1", "part2", "part3")
    end
  end

  test "dig uppercases all parts" do
    with_env("LOWERCASE__PARTS" => "uppercase_result") do
      assert_equal "uppercase_result", GlobalConfig.dig("lowercase", "parts")
    end
  end

  test "dig normalizes mixed-case parts" do
    with_env("MIXED__CASE__PARTS" => "result") do
      assert_equal "result", GlobalConfig.dig("MiXeD", "cAsE", "PaRtS")
    end
  end

  test "dig works with a single part" do
    with_env("SINGLE" => "value") do
      assert_equal "value", GlobalConfig.dig("single")
    end
  end

  test "dig returns the provided default when the environment variable is missing" do
    with_env("MISSING__NESTED__VAR" => nil) do
      assert_equal "default", GlobalConfig.dig("missing", "nested", "var", default: "default")
    end
  end

  test "dig returns nil when no default is provided and credentials return nil" do
    with_env("MISSING__NESTED__VAR" => nil) do
      GlobalConfig.stub :fetch_from_credentials, nil do
        assert_nil GlobalConfig.dig("missing", "nested", "var")
      end
    end
  end

  test "dig falls back to Rails credentials for nested keys" do
    with_env("PART1__PART2__PART3" => nil) do
      GlobalConfig.stub :fetch_from_credentials, "credential_value" do
        assert_equal "credential_value", GlobalConfig.dig("part1", "part2", "part3")
      end
    end
  end

  test "dig returns nil when the nested environment variable is blank" do
    with_env("NESTED__BLANK__VAR" => "  ") do
      GlobalConfig.stub :fetch_from_credentials, nil do
        assert_nil GlobalConfig.dig("nested", "blank", "var")
      end
    end
  end
end
