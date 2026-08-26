#!/usr/bin/env ruby
# frozen_string_literal: true

# Commit and push all current changes without changing the version number.
#
# Usage:
#   tools/snapshot.rb [message]   # optional commit message
#   tools/snapshot.rb --help

require 'optparse'
require 'open3'

ROOT = File.expand_path('..', __dir__)

def colorize(text, code)
  $stdout.tty? ? "\e[#{code}m#{text}\e[0m" : text
end

def green(t); colorize(t, 32); end
def red(t);   colorize(t, 31); end
def bold(t);  colorize(t, 1);  end

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

parser = OptionParser.new do |o|
  o.banner = 'Usage: snapshot.rb [message] [options]'
  o.on('--help') { puts o; exit 0 }
  o.on('--version') { puts "snapshot.rb v1.0"; exit 0 }
end
parser.parse!(ARGV)

message = ARGV.join(' ').strip
message = 'Snapshot' if message.empty?

puts bold("Snapshot: #{message}")

git('add', '-A')
git('commit', '-m', message)
puts green("  ✓ Committed: #{message}")

git('push')
puts green("  ✓ Pushed to origin")

puts bold("Done.")