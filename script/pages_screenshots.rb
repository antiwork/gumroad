#!/usr/bin/env ruby
# frozen_string_literal: true

# Take screenshots of the Pages feature for PR documentation
# Usage: RAILS_ENV=test bin/rails runner script/pages_screenshots.rb

require "capybara"
require "capybara/dsl"
require "selenium-webdriver"

Capybara.register_driver :headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--window-size=1440,900")
  options.add_argument("--disable-gpu")
  options.add_argument("--no-sandbox")
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

Capybara.default_driver = :headless_chrome
Capybara.app_host = "http://localhost:3000"
Capybara.run_server = false

include Capybara::DSL

seller = User.find_by(email: "seller@gumroad.com")
Feature.activate(:pages)

# Sign in via Warden test helper isn't available outside tests.
# Instead, use direct session manipulation through the login form.
# Since 2FA is disabled, login should work.

visit "/login"
fill_in "Email", with: "seller@gumroad.com"
fill_in "Password", with: "password"
click_button "Login"
sleep 3

puts "Current URL: #{current_url}"

if current_url.include?("dashboard") || current_url.include?("products")
  puts "Login successful!"

  # Screenshot 1: Pages index (empty)
  visit "/pages"
  sleep 2
  save_screenshot("qa-media/pr-5171-pages-index-empty.png")
  puts "Saved: pages-index-empty.png"

  # Create test pages
  seller.pages.create!(title: "My Landing Page", slug: "my-landing-page-ss")
  seller.pages.create!(
    title: "Product Showcase",
    slug: "product-showcase-ss",
    published: true,
    published_at: Time.current,
    html_content: '<div class="min-h-screen bg-gradient-to-b from-gray-900 to-black text-white"><section class="max-w-4xl mx-auto px-6 py-24 text-center"><h1 class="text-6xl font-bold mb-6">Master Web Development</h1><p class="text-xl text-gray-300 mb-12">Learn the skills that will change your career.</p><a href="#" class="bg-indigo-600 hover:bg-indigo-700 text-white px-8 py-4 rounded-lg text-lg font-semibold">Get Started - $49</a></section><section class="max-w-6xl mx-auto px-6 py-16 grid md:grid-cols-3 gap-8"><div class="bg-gray-800/50 rounded-lg p-8"><h3 class="text-xl font-bold mb-3">10+ Hours</h3><p class="text-gray-400">Deep dive into modern web tech.</p></div><div class="bg-gray-800/50 rounded-lg p-8"><h3 class="text-xl font-bold mb-3">Real Projects</h3><p class="text-gray-400">Build production apps from scratch.</p></div><div class="bg-gray-800/50 rounded-lg p-8"><h3 class="text-xl font-bold mb-3">Lifetime Access</h3><p class="text-gray-400">Updates forever. No recurring fees.</p></div></section></div>',
  )

  # Screenshot 2: Pages index with pages
  visit "/pages"
  sleep 2
  save_screenshot("qa-media/pr-5171-pages-index-list.png")
  puts "Saved: pages-index-list.png"

  # Screenshot 3: New page form
  visit "/pages/new"
  sleep 2
  save_screenshot("qa-media/pr-5171-pages-new.png")
  puts "Saved: pages-new.png"

  # Screenshot 4: Page editor
  visit "/pages/product-showcase-ss/edit"
  sleep 3
  save_screenshot("qa-media/pr-5171-pages-editor.png")
  puts "Saved: pages-editor.png"

  # Cleanup
  seller.pages.where(slug: ["my-landing-page-ss", "product-showcase-ss"]).each(&:mark_deleted!)
  puts "Done! Screenshots saved in qa-media/"
else
  puts "Login failed. URL: #{current_url}"
  save_screenshot("qa-media/pr-5171-login-failed.png")
end
