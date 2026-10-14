# frozen_string_literal: true

require "test_helper"

# bin/ci-test-packages copies the test image's toolchain onto the CI runner by hand.
# Specs pass on the runner and on the image alike only while the copies match.
class CiRunnerImageParityTest < ActiveSupport::TestCase
  IMAGE_DOCKERFILES = %w[docker/base/Dockerfile docker/base/Dockerfile.test docker/web/Dockerfile.test].freeze
  WKHTMLTOPDF_URL = %r{https://github\.com/wkhtmltopdf/wkhtmltopdf/releases/download/\S+?\.tar\.xz}
  IMAGEMAGICK_LIMIT = /name="(\w+)" value="\)\[\^"\]\+"\/\\1(\w+)"/

  def read(path) = Rails.root.join(path).read
  def runner = read("bin/ci-test-packages")
  def image = IMAGE_DOCKERFILES.map { |path| read(path) }.join("\n")

  test "the runner installs the image's Chrome" do
    image_version = image[/^ARG CHROME_VERSION=(\S+)$/, 1]
    assert image_version, "no ARG CHROME_VERSION in the image Dockerfiles"
    assert_equal image_version, runner[/^CHROME_VERSION=(\S+)$/, 1]
  end

  test "the runner installs the image's wkhtmltopdf" do
    image_url = image[WKHTMLTOPDF_URL]
    assert image_url, "no wkhtmltopdf download in the image Dockerfiles"
    assert_equal image_url, runner[WKHTMLTOPDF_URL]
  end

  test "the runner's Node major matches the image's" do
    runner_major = JSON.parse(read("package.json")).dig("engines", "node")[/\d+/]
    image_majors = image.scan(%r{deb\.nodesource\.com/node_(\d+)\.x}).flatten.uniq
    assert_equal [runner_major], image_majors
  end

  test "the runner sets the image's ImageMagick limits" do
    image_limits = image.scan(IMAGEMAGICK_LIMIT).to_h
    assert_equal %w[disk height memory width], image_limits.keys.sort
    assert_equal image_limits, runner.scan(IMAGEMAGICK_LIMIT).to_h
  end

  test "the image installs every package the runner installs" do
    runner_packages = runner[/^PACKAGES=\((.+)\)$/, 1].split
    image_packages = image.scan(/^\s+([a-z0-9][\w.+-]*) \\$/).flatten
    assert_empty runner_packages - image_packages
  end
end
