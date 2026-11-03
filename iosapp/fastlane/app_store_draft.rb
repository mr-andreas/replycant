# Decides how a release tag becomes an App Store draft without calling
# App Store Connect. The lane applies the decision; these rules stay
# testable when the API is unavailable.
module AppStoreDraft
  class Error < StandardError; end

  # Versions get_edit_app_store_version can return that still accept a
  # build and a new screenshot set. Waiting for review is editable in
  # Apple's filter but must not be overwritten by a release tag.
  EDITABLE_STATES = %w[
    PREPARE_FOR_SUBMISSION
    DEVELOPER_REJECTED
    REJECTED
    METADATA_REJECTED
    INVALID_BINARY
  ].freeze

  REVIEW_STATES = %w[
    WAITING_FOR_REVIEW
    IN_REVIEW
  ].freeze

  TIMELINE_SNAPSHOT = "01-timeline"
  MAP_SNAPSHOT = "02-map"

  # Returns :create or :reuse. Raises when attaching a build would
  # rename another draft or change a version already in review.
  def self.version_action(marketing_version:, editable_version:, editable_state:, in_review_version: nil)
    if in_review_version
      raise Error, "Version #{in_review_version} is IN_REVIEW. The draft waits until that review finishes."
    end

    return :create if editable_version.nil? || editable_version.empty?

    if editable_version != marketing_version
      raise Error,
        "App Store Connect already has editable version #{editable_version}. " \
        "Refusing to replace it with #{marketing_version}."
    end

    if REVIEW_STATES.include?(editable_state)
      raise Error, "Version #{marketing_version} is #{editable_state}. The draft does not change a version in review."
    end

    unless EDITABLE_STATES.include?(editable_state)
      raise Error, "Version #{marketing_version} is #{editable_state}, which cannot take a new build."
    end

    :reuse
  end

  # App Store listing images are the simulator captures. Framed PNGs are
  # a README asset and must not be the upload directory.
  def self.screenshot_upload_directory(fastlane_dir)
    File.expand_path(File.join("screenshots", "en-US"), fastlane_dir)
  end

  # Deliver sorts each device's screenshot set by natural filename order.
  # The same sort has to put the timeline first and the map second, or
  # the listing would show the wrong screen in the first slot.
  def self.ordered_listing!(filenames)
    groups = {}
    filenames.each do |filename|
      base = File.basename(filename.to_s)
      next if framed_screenshot?(base)
      next unless base.end_with?(".png")

      match = base.match(/\A(.+)-(\d{2}-.+)\.png\z/)
      unless match
        raise Error, "Screenshot #{base} must be named {device}-{nn}-{name}.png so listing order stays stable."
      end

      (groups[match[1]] ||= []) << base
    end

    raise Error, "No unframed App Store screenshots to upload." if groups.empty?

    groups.each_with_object({}) do |(device, names), ordered|
      sorted = natural_sort(names)
      first = snapshot_name(sorted[0])
      second = snapshot_name(sorted[1])
      unless first == TIMELINE_SNAPSHOT && second == MAP_SNAPSHOT
        raise Error,
          "#{device} must list #{TIMELINE_SNAPSHOT} then #{MAP_SNAPSHOT}. " \
          "Order would be #{sorted.join(', ')}."
      end
      ordered[device] = sorted
    end
  end

  # Deliver reads language folders inside the screenshots path, and
  # uploads *_framed.png instead of the raw captures when both are
  # present. The staged tree is only en-US raw files, in listing order.
  def self.stage_listing!(source_dir, destination_root)
    require "fileutils"

    basenames = Dir.glob(File.join(source_dir, "*.png")).map { |path| File.basename(path) }
    ordered = ordered_listing!(basenames)
    destination = File.join(destination_root, "en-US")
    FileUtils.mkdir_p(destination)
    ordered.each_value do |names|
      names.each do |name|
        FileUtils.cp(File.join(source_dir, name), File.join(destination, name))
      end
    end
    destination_root
  end

  # Matches deliver's filename sort so a 2-prefix stays ahead of a
  # 10-prefix. String sort would reverse those.
  def self.natural_sort(names)
    names.sort { |left, right| natural_compare(left, right) }
  end

  def self.framed_screenshot?(filename)
    filename.end_with?("_framed.png")
  end

  def self.snapshot_name(filename)
    return nil unless filename

    filename[/\A.+-(\d{2}-.+)\.png\z/, 1]
  end

  def self.natural_compare(left, right)
    left_parts = left.scan(/\d+|\D+/)
    right_parts = right.scan(/\d+|\D+/)
    [left_parts.length, right_parts.length].max.times do |index|
      left_part = left_parts[index]
      right_part = right_parts[index]
      return -1 if left_part.nil?
      return 1 if right_part.nil?

      comparison = if left_part.match?(/\A\d+\z/) && right_part.match?(/\A\d+\z/)
        left_part.to_i <=> right_part.to_i
      else
        left_part <=> right_part
      end
      return comparison unless comparison.zero?
    end
    0
  end

  private_class_method :framed_screenshot?, :snapshot_name, :natural_compare
end
