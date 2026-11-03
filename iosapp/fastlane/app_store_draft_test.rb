# Locks the draft workflow's decisions that must not depend on App Store
# Connect: which version to open, where unframed screenshots live, and
# that each device lists the timeline before the map.
require "fileutils"
require "tmpdir"
require_relative "app_store_draft"

FAILURES = []

def check(label)
  yield
  puts "ok #{label}"
rescue StandardError => error
  FAILURES << "#{label}: #{error.message}"
  puts "FAIL #{label}: #{error.message}"
end

def assert_equal(actual, expected)
  return if actual == expected

  raise "expected #{expected.inspect}, got #{actual.inspect}"
end

def expect_error(pattern)
  yield
  raise "expected an error matching #{pattern.inspect}"
rescue AppStoreDraft::Error => error
  raise "error #{error.message.inspect} did not match #{pattern.inspect}" unless error.message.match?(pattern)
end

DEVICES = [
  "iPhone 17 Pro",
  "iPhone 17 Pro Max",
  "iPad Pro 13-inch (M5)"
].freeze

check("creates a version when nothing is editable") do
  action = AppStoreDraft.version_action(
    marketing_version: "1.2.3",
    editable_version: nil,
    editable_state: nil
  )
  assert_equal(action, :create)
end

check("reuses an editable version with the same number") do
  %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].each do |state|
    action = AppStoreDraft.version_action(
      marketing_version: "1.2.3",
      editable_version: "1.2.3",
      editable_state: state
    )
    assert_equal(action, :reuse)
  end
end

check("refuses to replace a different editable version") do
  expect_error(/1\.2\.0.*1\.2\.3|1\.2\.3.*1\.2\.0/) do
    AppStoreDraft.version_action(
      marketing_version: "1.2.3",
      editable_version: "1.2.0",
      editable_state: "PREPARE_FOR_SUBMISSION"
    )
  end
end

check("refuses a version already waiting for review") do
  expect_error(/WAITING_FOR_REVIEW/) do
    AppStoreDraft.version_action(
      marketing_version: "1.2.3",
      editable_version: "1.2.3",
      editable_state: "WAITING_FOR_REVIEW"
    )
  end
end

check("refuses while a version is in review") do
  expect_error(/IN_REVIEW/) do
    AppStoreDraft.version_action(
      marketing_version: "1.2.3",
      editable_version: nil,
      editable_state: nil,
      in_review_version: "1.2.3"
    )
  end
end

check("refuses a state that cannot take a build") do
  expect_error(/READY_FOR_SALE/) do
    AppStoreDraft.version_action(
      marketing_version: "1.2.3",
      editable_version: "1.2.3",
      editable_state: "READY_FOR_SALE"
    )
  end
end

check("uploads the raw en-US captures") do
  directory = AppStoreDraft.screenshot_upload_directory("/tmp/fastlane")
  raise "framed path #{directory}" if directory.include?("framed")
  raise "raw directory #{directory}" unless directory.end_with?("/screenshots/en-US")
end

check("lists the timeline first and the map second for each device") do
  filenames = DEVICES.flat_map do |device|
    [
      "#{device}-02-map.png",
      "#{device}-01-timeline_framed.png",
      "#{device}-01-timeline.png"
    ]
  end
  order = AppStoreDraft.ordered_listing!(filenames)
  DEVICES.each do |device|
    names = order.fetch(device)
    raise "#{device} first is #{names[0]}" unless names[0].end_with?("-01-timeline.png")
    raise "#{device} second is #{names[1]}" unless names[1].end_with?("-02-map.png")
    raise "#{device} included a framed file" if names.any? { |name| name.include?("_framed") }
  end
end

check("uses natural order so a later number cannot precede an earlier one") do
  ordered = AppStoreDraft.natural_sort([
    "iPhone 17 Pro-10-later.png",
    "iPhone 17 Pro-2-sooner.png"
  ])
  assert_equal(ordered, [
    "iPhone 17 Pro-2-sooner.png",
    "iPhone 17 Pro-10-later.png"
  ])
end

check("stages a clean en-US folder for deliver") do
  Dir.mktmpdir do |dir|
    source = File.join(dir, "source")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "iPhone 17 Pro-02-map.png"), "map")
    File.write(File.join(source, "iPhone 17 Pro-01-timeline.png"), "timeline")
    File.write(File.join(source, "iPhone 17 Pro-01-timeline_framed.png"), "framed")

    root = AppStoreDraft.stage_listing!(source, File.join(dir, "upload"))
    listing = Dir.children(File.join(root, "en-US")).sort
    assert_equal(listing, [
      "iPhone 17 Pro-01-timeline.png",
      "iPhone 17 Pro-02-map.png"
    ])
  end
end

check("refuses a device whose first image is not the timeline") do
  expect_error(/01-timeline/) do
    AppStoreDraft.ordered_listing!([
      "iPhone 17 Pro-01-map.png",
      "iPhone 17 Pro-02-timeline.png"
    ])
  end
end

unless FAILURES.empty?
  warn "#{FAILURES.length} failed"
  exit 1
end
