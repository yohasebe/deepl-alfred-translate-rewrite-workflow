#!/usr/bin/env ruby
# frozen_string_literal: true

# Build the distribution bundle from an explicit allowlist.
#
#   ruby scripts/pack_workflow.rb            # check only
#   ruby scripts/pack_workflow.rb --write    # check, then write the bundle
#
# Why not Alfred's GUI export: it puts everything in the workflow directory
# except prefs.plist into the zip. Anything a run leaves behind ships. That is
# how twelve microphone recordings, a log of local file paths, `tags`, and
# `info.plist.bak` reached published bundles across four repositories in
# September 2026. "Look at the folder before exporting" is not a control.
#
# The check runs in BOTH directions, and either one failing stops the build:
#
#   listed but missing  -> we would ship an incomplete workflow
#   present but unknown -> we would ship something nobody decided to ship
#
# One direction is not enough. finder-unclutter shipped 54 files with its
# icon.png deleted and no error, because a workflow without an icon installs
# fine and nothing complained.
#
# Fixed content is listed by name. Only the places where Alfred generates the
# names are matched by pattern: it writes `<object-uid>.png` beside the
# workflow when a node is given an icon, so "every png at the root" would be
# the wrong rule.

require "fileutils"
require "tmpdir"

# The installed workflow folder. It is outside this repository and its name is
# an Alfred-assigned UUID, so it is read from the environment and the default is
# only a convenience for the machine this was written on.
WF = ENV["ALFRED_WORKFLOW_DIR"] ||
  File.expand_path("~/Library/CloudStorage/Dropbox/alfred/Alfred.alfredpreferences/" \
                   "workflows/user.workflow.B310AA94-5F8B-4903-9899-991939976462")
REPO = File.expand_path("..", __dir__)
BUNDLE = File.join(REPO, "deepl-alfred-translate-rewrite.alfredworkflow")

# --- the allowlist ----------------------------------------------------------

RUBY_FILES = %w[
  alfred-deepl.rb alfred-deepl-usage.rb alfred-deepl-upload.rb
  alfred-deepl-download.rb alfred-deepl-check-uploaded.rb alfred-deepl-webui.rb
  deepl-api.rb config.rb
].freeze

# Screen-capture OCR calls the macOS text recognition through JXA.
SCRIPT_FILES = %w[alfred-deepl-ocr.js].freeze

OTHER_FILES = %w[
  info.plist webui.html icon.png icon-mini.png LICENSE README.md
].freeze

NAMED = (RUBY_FILES + SCRIPT_FILES + OTHER_FILES).freeze

# Alfred generates these names; they cannot be listed.
GENERATED = [
  /\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.png\z/,
  %r{\AList Filter Images/[^/]+\.png\z}
].freeze

# Deliberately never shipped. Named so that finding one is not a surprise.
EXCLUDED = ["prefs.plist"].freeze

# --- gather -----------------------------------------------------------------

on_disk = Dir.glob("#{WF}/**/*", File::FNM_DOTMATCH)
          .select { |p| File.file?(p) }
          .map { |p| p.sub("#{WF}/", "") }
          .sort

allowed  = on_disk.select { |f| NAMED.include?(f) || GENERATED.any? { |re| f =~ re } }
excluded = on_disk.select { |f| EXCLUDED.include?(f) }
unknown  = on_disk - allowed - excluded
missing  = NAMED - on_disk

puts "workflow folder: #{on_disk.length} files"
puts "  to ship:  #{allowed.length}"
puts "  excluded: #{excluded.length} #{excluded.inspect}"
puts

problems = false

unless missing.empty?
  puts "LISTED BUT MISSING (#{missing.length}) - the bundle would be incomplete:"
  missing.each { |f| puts "  #{f}" }
  puts
  problems = true
end

unless unknown.empty?
  puts "PRESENT BUT UNKNOWN (#{unknown.length}) - nobody decided to ship these:"
  unknown.each { |f| puts "  #{f}" }
  puts "  Either delete them from the workflow folder, or add them to the"
  puts "  allowlist in this script if they genuinely belong in the release."
  puts
  problems = true
end

# A last look inside, independent of the lists above.
suspicious = allowed.select do |f|
  f =~ /\.(log|mp3|wav|m4a|webm|bak|orig|tmp)\z/i || f =~ %r{(\A|/)(tags|\.DS_Store|data\.json)\z}
end
unless suspicious.empty?
  puts "ALLOWLISTED BUT SUSPICIOUS (#{suspicious.length}): #{suspicious.inspect}"
  problems = true
end

# Alfred's export excludes exactly one name, prefs.plist. That is a denylist of
# length one: a second file holding a key would ship. An allowlist already
# refuses anything unrecognised, but the files we *do* ship are worth reading -
# a key pasted into a script would pass every check above.
SECRETS = /sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_|BEGIN (RSA |OPENSSH )?PRIVATE KEY|xox[baprs]-/.freeze
leaking = allowed.select do |f|
  next false if f =~ /\.(png|woff2|icns)\z/i   # binary, and not where a key hides
  File.binread(File.join(WF, f)) =~ SECRETS
end
unless leaking.empty?
  puts "SECRET-SHAPED STRINGS in files we would ship (#{leaking.length}):"
  leaking.each { |f| puts "  #{f}" }
  problems = true
end

# And the local-environment traces that should not travel either.
traces = allowed.select do |f|
  next false if f =~ /\.(png|woff2|icns)\z/i
  File.binread(File.join(WF, f)) =~ %r{/Users/[a-z]}i
end
unless traces.empty?
  puts "ABSOLUTE HOME PATHS in files we would ship (#{traces.length}): #{traces.inspect}"
  problems = true
end

if problems
  puts "Refusing to build."
  exit 1
end

puts "Allowlist agrees with the folder in both directions."

exit 0 unless ARGV.include?("--write")

# --- build ------------------------------------------------------------------

tmp = File.join(Dir.tmpdir, "pack-#{Process.pid}.zip")
File.delete(tmp) if File.exist?(tmp)
# Alfred's own export writes a directory entry for each directory it ships.
# Extractors do not need them, but matching the structure of the artefact
# Alfred produces keeps this bundle from being the odd one out.
dirs = allowed.map { |f| File.dirname(f) }
              .reject { |d| d == "." }
              .flat_map { |d| d.split("/").each_with_object([]) { |part, acc| acc << (acc.empty? ? part : "#{acc.last}/#{part}") } }
              .uniq.sort.map { |d| "#{d}/" }

Dir.chdir(WF) do
  # -X drops extra attributes so the zip is reproducible between machines.
  args = ["zip", "-X", "-q", tmp] + dirs + allowed
  system(*args) or abort "zip failed"
end

# Verify what was actually written, rather than trusting the command.
written = `unzip -Z1 "#{tmp}"`.lines.map(&:chomp).reject(&:empty?).sort
if written != (dirs + allowed).sort
  puts "the zip does not contain what we asked for:"
  puts "  only in zip:    #{(written - dirs - allowed).inspect}"
  puts "  missing in zip: #{((dirs + allowed) - written).inspect}"
  File.delete(tmp)
  exit 1
end

Dir.mktmpdir do |dir|
  system("unzip", "-q", "-o", tmp, "-d", dir, out: File::NULL) or abort "unzip failed"
  differing = allowed.reject do |f|
    File.binread(File.join(WF, f)) == File.binread(File.join(dir, f))
  end
  unless differing.empty?
    puts "content differs from the folder: #{differing.inspect}"
    File.delete(tmp)
    exit 1
  end
end

FileUtils.mv(tmp, BUNDLE)
puts "wrote #{BUNDLE} (#{allowed.length} entries, #{File.size(BUNDLE)} bytes)"
