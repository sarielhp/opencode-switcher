#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit/integration test suite for the `oc` opencode-switcher script.
#
# Loads the function definitions from `oc` (everything above the "Main Execution
# Dispatcher" marker) into an isolated, temporary HOME and exercises the pure and
# filesystem-touching helpers directly — no real OpenCode binary or network is
# required.
#
# Usage:
#   tools/test.rb            # run all tests
#   tools/test.rb -v         # verbose (print each assertion)
#   tools/test.rb <pattern>  # only run tests whose group/name matches a regex
#   tools/test.rb --help
#
# Exit status is 0 when every test passes, 1 otherwise.

require 'optparse'
require 'fileutils'
require 'json'
require 'shellwords'
require 'tmpdir'
require 'open3'

ROOT = File.expand_path('..', __dir__)
OC_FILE = File.join(ROOT, 'oc')

def colorize(text, code)
  $stdout.tty? ? "\e[#{code}m#{text}\e[0m" : text
end

def green(t);  colorize(t, 32); end
def red(t);    colorize(t, 31); end
def yellow(t); colorize(t, 33); end
def bold(t);   colorize(t, 1);  end

OPTIONS = { verbose: false, pattern: nil }
parser = OptionParser.new do |o|
  o.banner = 'Usage: test.rb [-v] [pattern]'
  o.on('-v', '--verbose', 'Print every assertion') { OPTIONS[:verbose] = true }
  o.on('--help') { puts o; exit 0 }
end
parser.parse!(ARGV)
OPTIONS[:pattern] = ARGV.shift

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
$passed = 0
$failed = 0
$current_group = nil
$last_printed_group = nil
$failures = []

def group(name)
  $current_group = name
end

def test(name)
  full = "#{$current_group} > #{name}"
  return if OPTIONS[:pattern] && full !~ /#{OPTIONS[:pattern]}/i
  if $current_group != $last_printed_group
    print bold("\n#{$current_group}\n")
    $last_printed_group = $current_group
  end
  begin
    yield
    $passed += 1
    puts "  #{green('PASS')} #{name}" if OPTIONS[:verbose]
  rescue StandardError => e
    $failed += 1
    $failures << [full, e.message]
    puts "  #{red('FAIL')} #{name}"
    puts "       #{e.message}"
  end
end

def assert(cond, msg = 'assertion failed')
  raise msg.to_s unless cond
end

def assert_equal(expected, actual, msg = nil)
  return if expected == actual
  raise "#{msg || 'not equal'}\n       expected: #{expected.inspect}\n       actual:   #{actual.inspect}"
end

# ---------------------------------------------------------------------------
# Load `oc`'s definitions into an isolated HOME
# ---------------------------------------------------------------------------
# Give each run its own HOME so SWITCH_DIR / OPENCODE_DIR / TARGET_CFG resolve
# inside a throwaway directory. The `oc` source is eval'd only up to the main
# dispatcher so nothing executes on load.
FAKE_HOME = Dir.mktmpdir('oc-test-home-')
ENV['HOME'] = FAKE_HOME

oc_src = File.read(OC_FILE)
marker = '# Main Execution Dispatcher'
head = oc_src[0...oc_src.index(marker)]
# Strip the shebang; everything else (constants, helpers) is safe to load.
head = head.sub(/\A#!.*\n/, '')
# Silence the legacy-migration block's side effects under a fresh HOME (no-op).
eval(head, TOPLEVEL_BINDING) # rubocop:disable Security/Eval

# Convenience: reset SWITCH_DIR/OPENCODE_DIR contents between filesystem tests.
def reset_dirs
  FileUtils.rm_rf(SWITCH_DIR)
  FileUtils.rm_rf(OPENCODE_DIR)
  FileUtils.mkdir_p(SWITCH_DIR)
  FileUtils.mkdir_p(OPENCODE_DIR)
end

def write_profile(num, model: 'p/model', provider: 'prov', base_url: 'https://x/v1', apiKey: '{env:PROV_API_KEY}', api_var: 'PROV_API_KEY', api_val: 'secret')
  dir = File.join(SWITCH_DIR, num)
  FileUtils.mkdir_p(dir)
  cfg = {
    'model' => model,
    'provider' => {
      provider => { 'options' => { 'baseURL' => base_url, 'apiKey' => apiKey } }
    }
  }
  File.write(File.join(dir, 'config.json'), JSON.pretty_generate(cfg))
  File.write(File.join(dir, 'API_key.sh'),
             "#!/usr/bin/env bash\nexport #{api_var}=#{Shellwords.escape(api_val)}\n")
  dir
end

# ===========================================================================
# parse_jsonc
# ===========================================================================
group 'parse_jsonc'
test 'plain object' do
  assert_equal({ 'a' => 1 }, parse_jsonc('{"a": 1}'))
end
test 'trailing comma in object' do
  assert_equal({ 'a' => 1 }, parse_jsonc('{"a": 1,}'))
end
test 'trailing comma in array' do
  assert_equal({ 'a' => [1, 2] }, parse_jsonc('{"a": [1, 2, ]}'))
end
test 'trailing comma nested' do
  assert_equal({ 'a' => { 'b' => 1 } }, parse_jsonc('{"a": {"b": 1, }, }'))
end
test 'comma-brace inside string is preserved' do
  assert_equal({ 'p' => 'say, } hello' }, parse_jsonc('{"p": "say, } hello"}'))
end
test 'comma-bracket inside string is preserved' do
  assert_equal({ 'p' => 'a, ] b' }, parse_jsonc('{"p": "a, ] b"}'))
end
test 'value ending in comma' do
  assert_equal({ 's' => 'x,' }, parse_jsonc('{"s": "x,"}'))
end
test 'line comments removed' do
  assert_equal({ 'a' => 1 }, parse_jsonc("{\n// comment\n\"a\": 1}"))
end
test 'block comments removed' do
  assert_equal({ 'a' => 1 }, parse_jsonc('{"a": /* c */ 1}'))
end
test 'comment containing a quote' do
  assert_equal({ 'a' => 1 }, parse_jsonc("// don't\n{\"a\": 1}"))
end
test 'url with // in string' do
  assert_equal({ 'url' => 'http://x/y' }, parse_jsonc('{"url": "http://x/y"}'))
end
test 'escaped quotes in string' do
  assert_equal({ 'a' => 'he said "hi"' }, parse_jsonc('{"a": "he said \\"hi\\""}'))
end
test 'trailing comma then next key' do
  assert_equal({ 'a' => 1, 'b' => ']' }, parse_jsonc('{"a": 1, "b": "]"}' ))
end
test 'comma-bearing key' do
  assert_equal({ 'a,' => 'b' }, parse_jsonc('{"a,": "b",}'))
end
test 'empty string input' do
  assert_equal({}, parse_jsonc(''))
end
test 'nil input' do
  assert_equal({}, parse_jsonc(nil))
end
test 'malformed raises (does not silently corrupt)' do
  raised = false
  begin
    parse_jsonc('{"a": ')
  rescue StandardError
    raised = true
  end
  assert raised, 'expected malformed input to raise'
end

# ===========================================================================
# format_num / get_default_profile
# ===========================================================================
group 'format_num'
test '"1" -> "01"' do
  assert_equal '01', format_num('1')
end
test '2 -> "02"' do
  assert_equal '02', format_num(2)
end
test '"" -> nil' do
  assert_equal nil, format_num('')
end
test '0 / negative -> nil' do
  assert_equal nil, format_num('0')
  assert_equal nil, format_num('-3')
end

group 'get_default_profile'
test 'reads default.json' do
  reset_dirs
  write_profile('01')
  write_profile('02')
  File.write(DEFAULT_FILE, JSON.generate('default' => '02'))
  assert_equal '02', get_default_profile
end
test 'empty default falls back to first profile' do
  reset_dirs
  write_profile('01')
  write_profile('02')
  File.write(DEFAULT_FILE, JSON.generate('default' => ''))
  assert_equal '01', get_default_profile
end
test 'invalid default falls back to first profile' do
  reset_dirs
  write_profile('03')
  File.write(DEFAULT_FILE, JSON.generate('default' => 'abc'))
  assert_equal '03', get_default_profile
end
test 'missing default.json falls back to first profile' do
  reset_dirs
  write_profile('04')
  assert_equal '04', get_default_profile
end

group 'available_profile_nums'
test 'numeric ordering (11 before 100)' do
  reset_dirs
  %w[100 02 11].each { |n| FileUtils.mkdir_p(File.join(SWITCH_DIR, n)) }
  assert_equal %w[02 11 100], available_profile_nums
end
test 'ignores non-directories' do
  reset_dirs
  FileUtils.mkdir_p(File.join(SWITCH_DIR, '01'))
  File.write(File.join(SWITCH_DIR, '02'), 'not a dir')
  assert_equal %w[01], available_profile_nums
end

# ===========================================================================
# inject_env_placeholders! / build_api_var_map
# ===========================================================================
group 'inject_env_placeholders!'
test 'empty map uses conventional fallback' do
  d = { 'provider' => { 'foo-bar' => { 'options' => { 'apiKey' => 'lit' } } } }
  inject_env_placeholders!(d, {})
  assert_equal '{env:FOO_BAR_API_KEY}', d['provider']['foo-bar']['options']['apiKey']
end
test 'provider-keyed map wins' do
  d = { 'provider' => { 'p' => { 'options' => { 'apiKey' => 'lit' } } } }
  inject_env_placeholders!(d, { 'p' => 'CUSTOM' })
  assert_equal '{env:CUSTOM}', d['provider']['p']['options']['apiKey']
end
test 'existing {env:} reference untouched' do
  d = { 'provider' => { 'p' => { 'options' => { 'apiKey' => '{env:EXISTING}' } } } }
  inject_env_placeholders!(d, { 'p' => 'NEW' })
  assert_equal '{env:EXISTING}', d['provider']['p']['options']['apiKey']
end
test 'only: scope leaves other providers alone' do
  d = { 'provider' => {
    'a' => { 'options' => { 'apiKey' => 'la' } },
    'b' => { 'options' => { 'apiKey' => 'lb' } }
  } }
  inject_env_placeholders!(d, { 'a' => 'A_KEY' }, only: ['a'])
  assert_equal '{env:A_KEY}', d['provider']['a']['options']['apiKey']
  assert_equal 'lb', d['provider']['b']['options']['apiKey']
end
test 'does not touch apiKeyURL-like keys' do
  d = { 'provider' => { 'p' => { 'options' => { 'apiKeyURL' => 'https://x', 'apiKey' => 'lit' } } } }
  inject_env_placeholders!(d, { 'p' => 'K' })
  assert_equal 'https://x', d['provider']['p']['options']['apiKeyURL']
  assert_equal '{env:K}', d['provider']['p']['options']['apiKey']
end

group 'build_api_var_map'
test 'multi-provider custom name maps nothing' do
  d = { 'provider' => {
    'openrouter' => { 'options' => { 'apiKey' => 'x' } },
    'anthropic'  => { 'options' => { 'apiKey' => 'y' } }
  } }
  assert_equal({}, build_api_var_map(d, 'MY_KEY'))
end
test 'multi-provider matched name maps one' do
  d = { 'provider' => {
    'openrouter' => { 'options' => { 'apiKey' => 'x' } },
    'anthropic'  => { 'options' => { 'apiKey' => 'y' } }
  } }
  assert_equal({ 'openrouter' => 'OPENROUTER_API_KEY' }, build_api_var_map(d, 'OPENROUTER_API_KEY'))
end
test 'single-provider custom name maps it' do
  d = { 'provider' => { 'openrouter' => { 'options' => { 'apiKey' => 'x' } } } }
  assert_equal({ 'openrouter' => 'MY_KEY' }, build_api_var_map(d, 'MY_KEY'))
end

# W1 end-to-end via the scoped injector
group 'set_api scope (W1)'
test 'multi-provider matched name preserves the other literal' do
  d = { 'provider' => {
    'openrouter' => { 'options' => { 'apiKey' => 'lit-or' } },
    'anthropic'  => { 'options' => { 'apiKey' => 'lit-an' } }
  } }
  m = build_api_var_map(d, 'OPENROUTER_API_KEY')
  inject_env_placeholders!(d, m, only: m.keys)
  assert_equal '{env:OPENROUTER_API_KEY}', d['provider']['openrouter']['options']['apiKey']
  assert_equal 'lit-an', d['provider']['anthropic']['options']['apiKey']
end

# ===========================================================================
# read_profile_api_vars (W2)
# ===========================================================================
group 'read_profile_api_vars'
test 'reads name and value' do
  reset_dirs
  dir = File.join(SWITCH_DIR, '01')
  FileUtils.mkdir_p(dir)
  api = File.join(dir, 'API_key.sh')
  File.write(api, "#!/usr/bin/env bash\nexport MY_KEY=#{Shellwords.escape('sk-x')}\n")
  vars = read_profile_api_vars(api)
  assert_equal [['MY_KEY', 'sk-x']], vars
end
test 'round-trips special characters byte-exactly' do
  reset_dirs
  dir = File.join(SWITCH_DIR, '01')
  FileUtils.mkdir_p(dir)
  api = File.join(dir, 'API_key.sh')
  %w[sk-plain-123].push('sk-with$pecial', 'sk-"dq', 'sk-back`tick', 'sk with space', 'sk;$semi', '').each do |key|
    File.write(api, "#!/usr/bin/env bash\nexport MY_KEY=#{Shellwords.escape(key)}\n")
    got = read_profile_api_vars(api).first
    assert_equal ['MY_KEY', key], got, "round-trip failed for #{key.inspect}"
  end
end
test 'missing file returns empty array' do
  assert_equal [], read_profile_api_vars('/nonexistent/API_key.sh')
end

# ===========================================================================
# atomic_write / sweep_stale_tmp_files
# ===========================================================================
group 'atomic_write'
test 'writes content and leaves no temp file' do
  reset_dirs
  path = File.join(SWITCH_DIR, 'out.json')
  atomic_write(path, '{"a":1}')
  assert_equal '{"a":1}', File.read(path)
  assert_equal [], Dir.glob("#{path}.tmp.*")
end
test 'preserves existing file mode' do
  reset_dirs
  path = File.join(SWITCH_DIR, 'mode.json')
  File.write(path, 'old')
  File.chmod(0o600, path)
  atomic_write(path, 'new')
  assert_equal 0o600, File.stat(path).mode & 0o777
end
test 'overwrites atomically (content replaced, valid)' do
  reset_dirs
  path = File.join(SWITCH_DIR, 'o.json')
  atomic_write(path, '{"n":1}')
  atomic_write(path, '{"n":2}')
  assert_equal({ 'n' => 2 }, JSON.parse(File.read(path)))
end

group 'sweep_stale_tmp_files'
test 'removes temp files from dead processes, keeps live ones' do
  reset_dirs
  dead = File.join(SWITCH_DIR, "default.json.tmp.99999999")
  live = File.join(SWITCH_DIR, "default.json.tmp.#{Process.pid}")
  File.write(dead, 'x')
  File.write(live, 'x')
  sweep_stale_tmp_files
  assert !File.exist?(dead), 'expected dead-process temp file to be removed'
  assert File.exist?(live), 'expected current-process temp file to be kept'
end

# ===========================================================================
# extract_model_override! / run_has_message?
# ===========================================================================
group 'extract_model_override!'
test 'extracts -m value and removes both tokens' do
  a = ['-m', 'custom/model', '-f', 'main.rb']
  assert_equal 'custom/model', extract_model_override!(a)
  assert_equal ['-f', 'main.rb'], a
end
test 'extracts --model=value form' do
  a = ['--model=x/y']
  assert_equal 'x/y', extract_model_override!(a)
  assert_equal [], a
end
test 'returns nil when absent' do
  a = ['--prompt', 'hi']
  assert_equal nil, extract_model_override!(a)
  assert_equal ['--prompt', 'hi'], a
end

group 'run_has_message?'
test 'bare run has no message' do
  assert_equal false, run_has_message?(['run'])
end
test 'run with positional has message' do
  assert_equal true, run_has_message?(['run', 'hello'])
end
test 'run with -m value has no message' do
  assert_equal false, run_has_message?(['run', '-m', 'x'])
end
test 'run with -- has message when payload follows' do
  assert_equal true, run_has_message?(['run', '--', 'hello'])
end

# ===========================================================================
# mask_key
# ===========================================================================
group 'mask_key'
test 'short key becomes dots' do
  assert_equal '••••••••', mask_key('short')
end
test 'long key shows head and tail' do
  assert_equal 'sk-abc12...wxyz', mask_key('sk-abc1234567890wxyz')
end
test 'empty key reports not set' do
  assert mask_key('').include?('NOT SET')
end

# ===========================================================================
# End-to-end CLI smoke test (real `oc`, stub opencode, sandbox HOME)
# ===========================================================================
group 'CLI end-to-end'
SBX = Dir.mktmpdir('oc-test-e2e-')
begin
  bin_dir = File.join(SBX, 'bin')
  FileUtils.mkdir_p(bin_dir)
  stub = File.join(bin_dir, 'opencode')
  File.write(stub, "#!/usr/bin/env bash\n[ \"$1\" = service ] && exit 1\necho \"ARGS: $*\"\n")
  FileUtils.chmod(0o755, stub)

  e2e_env = { 'HOME' => SBX, 'PATH' => "#{bin_dir}:#{ENV['PATH']}" }

  def run_oc(env, *args)
    Open3.capture3(env, 'ruby', OC_FILE, *args)
  end

  # Bootstrap a profile in the sandbox
  out, _err, st = run_oc(e2e_env, 'conf', 'list')
  assert st.success?, "conf list failed: #{out}"

  # Passthrough: oc -- --version forwards verbatim
  out, _err, _st = run_oc(e2e_env, '--', '--version')
  assert_equal 'ARGS: --version', out.strip

  # Passthrough after profile number
  out, _err, _st = run_oc(e2e_env, '01', '--', '-m', 'custom/model', '-f', 'main.rb')
  assert_equal 'ARGS: -m custom/model -f main.rb', out.strip

  # Normal run injects the profile model
  out, _err, _st = run_oc(e2e_env, '01', 'run', 'hello')
  assert out.strip.include?('run -m'), "expected -m injection, got: #{out.strip}"

  test 'CLI smoke: list, passthrough, and injection' do
    # Assertions above raise on failure; reaching here means they passed.
    assert true
  end
ensure
  FileUtils.rm_rf(SBX)
end

# ===========================================================================
# Diagnostics must not clobber the active default profile
# ===========================================================================
group 'compile_and_switch_profile activate_default'
test 'activate_default: false compiles config but keeps default.json' do
  reset_dirs
  write_profile('01', model: 'prov/one')
  write_profile('02', model: 'prov/two')
  File.write(DEFAULT_FILE, JSON.generate('default' => '01'))
  compile_and_switch_profile('02', reload: false, activate_default: false)
  # opencode.json now holds profile 02's config...
  assert_equal 'prov/two', JSON.parse(File.read(TARGET_CFG))['model']
  # ...but default.json still points at 01.
  assert_equal '01', JSON.parse(File.read(DEFAULT_FILE))['default']
end
test 'activate_default: true (default) updates default.json' do
  reset_dirs
  write_profile('01', model: 'prov/one')
  write_profile('02', model: 'prov/two')
  File.write(DEFAULT_FILE, JSON.generate('default' => '01'))
  compile_and_switch_profile('02', reload: false)
  assert_equal '02', JSON.parse(File.read(DEFAULT_FILE))['default']
end

group 'test_all_profiles restore'
test 'preserves the active default and its compiled config' do
  reset_dirs
  write_profile('01', model: 'prov/one')
  write_profile('02', model: 'prov/two')
  File.write(DEFAULT_FILE, JSON.generate('default' => '01'))
  # Prime the active config as if profile 01 were active.
  compile_and_switch_profile('01', reload: false)
  before_cfg = File.read(TARGET_CFG)
  before_default = JSON.parse(File.read(DEFAULT_FILE))['default']

  # Replace test_profile with a compile-only stub (no opencode/network) for the
  # duration of this test, then run the real test_all_profiles.
  Object.send(:alias_method, :__real_test_profile, :test_profile)
  Object.send(:define_method, :test_profile) do |p, _prompt = nil, abort_on_error: false|
    compile_and_switch_profile(p, reload: false, activate_default: false)
    true
  end
  begin
    test_all_profiles
  ensure
    Object.send(:alias_method, :test_profile, :__real_test_profile)
  end

  assert_equal before_default, JSON.parse(File.read(DEFAULT_FILE))['default'],
               'default.json should be unchanged after test all'
  assert_equal before_cfg, File.read(TARGET_CFG),
               'active opencode.json should be restored after test all'
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts ''
puts bold("Tests: #{$passed} passed, #{$failed} failed")
unless $failures.empty?
  puts red('Failures:')
  $failures.each { |(name, msg)| puts "  - #{name}: #{msg}" }
end

FileUtils.rm_rf(FAKE_HOME) if FAKE_HOME && File.directory?(FAKE_HOME)
exit($failed.zero? ? 0 : 1)
