# frozen_string_literal: true

require "spec_helper"

describe JSErrorReporter do
  before(:all) do
    options = Selenium::WebDriver::Chrome::Options.new.tap do |opts|
      opts.add_argument("--headless=new")
      opts.add_argument("--disable-gpu")
      opts.add_argument("--no-sandbox")
      opts.add_argument("--disable-dev-shm-usage")
      opts.add_argument("--user-data-dir=/tmp/chrome")
      opts.add_option("goog:loggingPrefs", { driver: "DEBUG" })
    end

    @driver = Selenium::WebDriver.for(:chrome, options: options)

    @html_tempfiles = []
  end

  after(:each) do
    @html_tempfiles.shift.close(true) while @html_tempfiles.size > 0
  end

  around do |example|
    JSErrorReporter.enabled = true
    example.run
  ensure
    JSErrorReporter.enabled = nil
  end

  def create_html_file(content)
    tempfile = Tempfile.new(["", ".html"])
    tempfile.write(content)
    tempfile.rewind
    @html_tempfiles << tempfile
    "file://#{tempfile.path}"
  end

  it "reports raised Error exceptions with stack trace" do
    url = create_html_file %{
      <script>
        function add(a, b) {
          throw new Error("Cannot add")
        }

        add(1, 2)
      </script>

    }
    @driver.navigate.to url

    errors = JSErrorReporter.instance.read_errors! @driver

    expect(errors.size).to eq 1
    line, first_trace = errors[0].split("\n")
    expect(line).to eq "Error: Cannot add"
    expect(first_trace).to eq "\tadd (#{url}:3:16)"
  end

  it "reports raised primitive value exceptions with stack trace" do
    url = create_html_file %{
      <script>
        function add(a, b) {
          throw "Cannot add"
        }

        add(1, 2)
      </script>

    }
    @driver.navigate.to url

    errors = JSErrorReporter.instance.read_errors! @driver

    expect(errors.size).to eq 1
    line, first_trace = errors[0].split("\n")
    expect(line).to eq "Error: Cannot add"
    expect(first_trace).to eq "\tadd (#{url}:3:10)"
  end

  it "reports console.error entries, including with multiple or complex arguments, with stack trace" do
    url = create_html_file %{
      <script>
        console.error("Test error log", 42, [null, false], { x: 1 }, { test: ["a", "b", "c"] });
      </script>
    }

    @driver.navigate.to url

    errors = JSErrorReporter.instance.read_errors! @driver

    expect(errors.size).to eq 1
    line, first_trace = errors[0].split("\n")
    # FIXME nested objects - can't format properly because Chrome WebDriver log data does not include properties for this level of nesting
    expect(line).to eq %{Console error: Test error log, 42, [null,false], {"x":1}, {"test":"Array(3)"}}
    expect(first_trace).to eq "\t (#{url}:2:16)"
  end

  # TODO see above
  pending "it formats nested objects in console.error properly"

  it "does not report console.log and console.warn entries" do
    url = create_html_file %{
      <script>
        console.log("Test info log")
        console.warn("Test warn log")
      </script>
    }

    @driver.navigate.to url

    errors = JSErrorReporter.instance.read_errors! @driver

    expect(errors.size).to eq 0
  end

  it "reports combinations of these properly" do
    url = create_html_file %{
      <script>
        console.log("Test info log")

        console.error("Sample error info")

        function add(a, b) {
          console.warn("Warning")
          throw new Error("Cannot add")
        }

        add(1, 2)
      </script>

    }
    @driver.navigate.to url

    errors = JSErrorReporter.instance.read_errors! @driver

    expect(errors.size).to eq 2

    line, first_trace = errors[0].split("\n")
    expect(line).to eq "Console error: Sample error info"
    expect(first_trace).to eq "\t (#{url}:4:16)"

    line, first_trace = errors[1].split("\n")
    expect(line).to eq "Error: Cannot add"
    expect(first_trace).to eq "\tadd (#{url}:8:16)"
  end

  # TODO
  pending "it presents source-mapped stack traces instead of raw ones"
end
