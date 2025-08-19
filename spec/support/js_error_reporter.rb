# frozen_string_literal: true

class JSErrorReporter
  def initialize
    @_ignored_js_errors = []
    @source_maps = Hash.new do |hash, key|
      hash[key] = begin
        sourcemap_uri = URI.parse(key).tap { |uri| uri.path += ".map" }
        if sourcemap_uri.path.match?(/\/assets\/application-.*\.js\.map/)
          sourcemap_uri.path = "/assets/application.js.map"
        end
        Sprockets::SourceMapUtils.decode_source_map(JSON.parse(Net::HTTP.get(sourcemap_uri)))
      rescue => e
        puts e.inspect
        nil
      end
    end
  end

  @instance = new
  @global_patterns = []

  class << self
    attr_reader :instance, :global_patterns
    attr_writer :enabled

    def set_global_ignores(array_of_patterns)
      @global_patterns = array_of_patterns
    end

    def enabled?
      @enabled.nil? ? ENV["ENABLE_RAISE_JS_ERROR"] == "1" : @enabled
    end
  end

  # ignore, once, an error matching the pattern (exact string or regex)
  def add_ignore_error(string_or_regex)
    @_ignored_js_errors ||= []
    @_ignored_js_errors << string_or_regex
  end

  def report_errors!(ctx)
    errors_to_log = read_errors!(ctx.page.driver.browser)
    ctx.aggregate_failures "javascript errors" do
      errors_to_log.each do |error|
        ctx.expect(error).to ctx.eq ""
      end
    end
  end

  def reset!
    @_ignored_js_errors = []
  end

  def read_errors!(driver)
    return [] unless self.class.enabled?

    # print the messages of console.error logs / unhandled exceptions, and fail the spec
    # (ignoring the error messages from a pattern specified above)
    errors = begin
      driver.logs.get(:driver)
    rescue => e
      puts e.inspect
      []
    end

    errors.map do |log|
      if log.message.start_with?("DevTools WebSocket Event: Runtime.exceptionThrown")
        error = JSON.parse(log.message[log.message.index("{")..])["exceptionDetails"]
        message = error["exception"]["preview"] ? error["exception"]["preview"]["properties"].find { |prop| prop["name"] == "message" }["value"] : error["exception"]["value"]
        next "Error: #{message}\n\tat #{error["url"]}:#{error["lineNumber"]}:#{error["columnNumber"]}" unless error["stackTrace"]
        trace = format_stack_trace(error["stackTrace"])
        "Error: #{message}\n#{trace}"
      elsif log.message.start_with?("DevTools WebSocket Event: Runtime.consoleAPICalled")
        log_data = JSON.parse(log.message[log.message.index("{")..])
        next unless log_data["type"] == "error"
        trace = format_stack_trace(log_data["stackTrace"])
        message = log_data["args"].map do |arg|
          parsed = format_object(arg)
          if parsed.is_a?(Hash) || parsed.is_a?(Array)
            parsed.to_json
          else
            parsed
          end
        end.join(", ")
        if trace.present?
          "Console error: #{message}\n#{trace}"
        else
          "Console error: #{message}"
        end
      end
    end.reject { |error| error.blank? || should_ignore_error?(error) }
  end

  private
    def format_object(obj)
      if obj["type"] == "object" && obj["preview"] && (obj["className"] == "Object" || obj["subtype"] == "array")
        if obj["preview"]["properties"]
          if obj["className"] == "Object"
            obj["preview"]["properties"].reduce({}) do |acc, prop|
              acc[prop["name"]] = format_object(prop)
              acc
            end
          else
            obj["preview"]["properties"].map { |prop| format_object(prop) }
          end
        else
          obj["preview"]["description"]
        end
      else
        if obj["subtype"] == "null"
          nil
        elsif obj["type"] == "boolean"
          obj["value"] == "true"
        elsif obj["type"] == "number"
          if obj["value"].is_a?(String)
            if obj["value"].include?(".")
              obj["value"].to_f
            else
              obj["value"].to_i
            end
          else
            obj["value"]
          end
        else
          obj["value"] || obj["description"]
        end
      end
    end

    def format_stack_trace(stackTrace)
      return nil if stackTrace.empty?

      stackTrace["callFrames"].filter_map do |frame|
        next if !frame["functionName"] && !frame["url"]

        source_map = frame["url"] && @source_maps[frame["url"]]
        mapped = source_map && Sprockets::SourceMapUtils.bsearch_mappings(source_map[:mappings], [frame["lineNumber"] + 1, frame["columnNumber"]])
        if mapped
          source = mapped[:source].start_with?("webpack://") ? mapped[:source][12..] : mapped[:source]
          "\t#{mapped[:name] || frame["functionName"]} (#{source}:#{mapped[:original][0]})"
        else
          "\t#{frame["functionName"]} (#{frame["url"]}:#{frame["lineNumber"]}:#{frame["columnNumber"]})"
        end
      end.join("\n")
    end

    def should_ignore_error?(error_message)
      should_ignore_based_on_global_pattern?(error_message) || should_ignore_based_on_one_off_pattern?(error_message)
    end

    def should_ignore_based_on_global_pattern?(error_message)
      self.class.global_patterns.any? { |p| error_matches_pattern?(error_message, p) }
    end

    def should_ignore_based_on_one_off_pattern?(error_message)
      @_ignored_js_errors.any? { |p| error_matches_pattern?(error_message, p) }
    end

    def error_matches_pattern?(error_message, pattern)
      pattern.is_a?(String) ? pattern == error_message : pattern.match(error_message)
    end
end
