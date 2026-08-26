#!/usr/bin/env ruby
# frozen_string_literal: true

# Bump the version number in the `oc` script, then commit and push.
# Does NOT merge main or create a GitHub tag (see release.rb for that).
#
# Usage:
#   tools/bump.rb [major|minor|patch]   # default: patch
#   tools/bump.rb 0.2.0                 # explicit version
#   tools/bump.rb --help

require 'optparse'
require 'open3'

ROOT = File.expand_path('..', __dir__)
OC_FILE = File.join(ROOT, 'oc')

def colorize(text, code)
  $stdout.tty? ? "\e[#{code}m#{text}\e[0m" : text
end

def green(t); colorize(t, 32); end
def red(t);   colorize(t, 31); end
def bold(t);  colorize(t, 1);  end

def current_version
  content = File.read(OC_FILE)
  m = content.match(/VERSION\s*=\s*'([^']+)'/)
  unless m
    warn red("Error: Could not find VERSION constant in #{OC_FILE}")
    exit 1
  end
  m[1]
end

def bump(version, part)
  nums = version.split('.').map(&:to_i)
  nums << 0 while nums.size < 3
  case part
  when 'major' then nums = [nums[0] + 1, 0, 0]
  when 'minor' then nums = [nums[0], nums[1] + 1, 0]
  else              nums = [nums[0], nums[1], nums[2] + 1]
  end
  nums.join('.')
end

def run(cmd, *args)
  _out, err, st = Open3.capture3(cmd, *args)
  unless st.success?
    warn red "Error: #{cmd} failed: #{err.strip}"
    exit 1
  end
  _out
end

def git(*args)
  run('git', *args)
end

opts = {}
parser = OptionParser.new do |o|
  o.banner = 'Usage: bump.rb [major|minor|patch|VERSION] [options]'
  o.on('--help') { puts o; exit 0 }
  o.on('--version') { puts "bump.rb v1.0"; exit 0 }
end
parser.parse!(ARGV)

bump_type = ARGV.shift || 'patch'
new_version = if bump_type =~ /^\d+\.\d+\.\d+$/
                bump_type
              elsif %w[major minor patch].include?(bump_type)
                bump(current_version, bump_type)
              else
                warn red "Error: Unknown bump type '#{bump_type}' (expected major|minor|patch or x.y.z)"
                exit 1
              end

old_version = current_version
puts bold("Bumping v#{old_version} -> v#{new_version}")

content = File.read(OC_FILE)
content.sub!(/VERSION\s*=\s*'[^']+'/, "VERSION      = '#{new_version}'")
File.write(OC_FILE, content)
puts green("  ✓ Bumped VERSION to #{new_version}")

git('add', '-A')
git('commit', '-m', "Bump version to v#{new_version}")
puts green("  ✓ Committed v#{new_version}")

git('push')
puts green("  ✓ Pushed to origin")

puts bold("Done: v#{old_version} -> v#{new_version}")