#!/usr/bin/env ruby
# frozen_string_literal: true

# Bump the version number in the `oc` script, commit, push, and tag the
# release on GitHub.
#
# Usage:
#   tools/release.rb [major|minor|patch]   # default: patch
#   tools/release.rb 0.2.0                 # explicit version
#   tools/release.rb --help

require 'optparse'
require 'open3'
require 'shellwords'

ROOT = File.expand_path('..', __dir__)
OC_FILE = File.join(ROOT, 'oc')

def colorize(text, code)
  $stdout.tty? ? "\e[#{code}m#{text}\e[0m" : text
end

def green(t); colorize(t, 32); end
def red(t);   colorize(t, 31); end
def yellow(t); colorize(t, 33); end
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
    warn red("Error: #{cmd} failed: #{err.strip}")
    exit 1
  end
  _out
end

def git(*args)
  run('git', *args)
end

def gh(*args)
  run('gh', *args)
end

opts = {}
parser = OptionParser.new do |o|
  o.banner = 'Usage: release.rb [major|minor|patch|VERSION] [options]'
  o.on('--help') { puts o; exit 0 }
  o.on('--version') { puts "release.rb v1.0"; exit 0 }
end
parser.parse!(ARGV)

bump_type = ARGV.shift || 'patch'
new_version = if bump_type =~ /^\d+\.\d+\.\d+$/
                bump_type
              elsif %w[major minor patch].include?(bump_type)
                bump(current_version, bump_type)
              else
                warn red("Error: Unknown bump type '#{bump_type}' (expected major|minor|patch or x.y.z)")
                exit 1
              end

old_version = current_version
puts bold("Releasing v#{old_version} -> v#{new_version}")

# 1. Bump version in oc
content = File.read(OC_FILE)
content.sub!(/VERSION\s*=\s*'[^']+'/, "VERSION      = '#{new_version}'")
File.write(OC_FILE, content)
puts green("  ✓ Bumped VERSION to #{new_version}")

# 2. Commit
git('add', 'oc')
git('commit', '-m', "Release v#{new_version}")
puts green("  ✓ Committed v#{new_version}")

# 3. Push
git('push')
puts green("  ✓ Pushed to origin")

# 3b. Fast-forward main to dev and push, so the tag points at the stable branch
current_branch = git('branch', '--show-current').strip
if current_branch == 'dev'
  git('checkout', 'main')
  git('pull', '--ff-only', 'origin', 'main')
  git('merge', '--ff-only', 'dev')
  git('push')
  git('checkout', 'dev')
  puts green("  ✓ Fast-forwarded main to dev and pushed")
else
  puts yellow("  Skipping main fast-forward (current branch is '#{current_branch}', not 'dev')")
end

# 4. Publish a GitHub release (also creates the tag)
gh('release', 'create', "v#{new_version}", '--title', "v#{new_version}", '--generate-notes')
puts green("  ✓ Released v#{new_version} on GitHub")

puts bold("Done: v#{old_version} -> v#{new_version}")