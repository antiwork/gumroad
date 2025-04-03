# frozen_string_literal: true

# Controller containing actions for endpoints that are used by Pingdom and alike to check that
# certain functionality is working and alive.
class TestController < ApplicationController
  # Public: Action that tests that outgoing traffic is possible.
  # Tests outgoing traffic by attempting to read an object from S3.
  def outgoing_traffic
    temp_file = Tempfile.new
    Aws::S3::Resource.new.bucket("gumroad").object("outgoing-traffic-healthcheck.txt").get(response_target: temp_file)
    temp_file.rewind
    render plain: temp_file.read
  end
end
