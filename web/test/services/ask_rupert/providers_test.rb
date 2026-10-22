# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class AskRupertProvidersTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def config(mode, env = {})
    env.each { |key, value| ENV[key] = value }
    AskRupert::Config.new('provider_mode' => mode)
  end

  teardown do
    %w[OLLAMA_URL ASK_RUPERT_LOCAL_MODEL ASK_RUPERT_OPENCODE_BIN].each { |key| ENV.delete(key) }
  end

  test 'cloud mode uses opencode only; local-only never touches the cloud' do
    assert_equal ['opencode'], AskRupert::Providers.for_turn(config('cloud'), 'hi').map(&:name)
    local = config('local_only', 'OLLAMA_URL' => 'http://127.0.0.1:11434', 'ASK_RUPERT_LOCAL_MODEL' => 'gemma4:e4b')
    assert_equal ['ollama'], AskRupert::Providers.for_turn(local, 'where is sync').map(&:name)
  end

  test 'auto mode sends short how-to questions to the local model first and data questions to the cloud' do
    auto = config('auto', 'OLLAMA_URL' => 'http://127.0.0.1:11434', 'ASK_RUPERT_LOCAL_MODEL' => 'gemma4:e4b')
    assert_equal %w[ollama opencode], AskRupert::Providers.for_turn(auto, 'How do I clock in?').map(&:name)
    assert_equal ['opencode'], AskRupert::Providers.for_turn(auto, 'What were total sales last week?').map(&:name)
    %w[OLLAMA_URL ASK_RUPERT_LOCAL_MODEL].each { |key| ENV.delete(key) }
    unconfigured = AskRupert::Config.new('provider_mode' => 'auto')
    assert_equal ['opencode'], AskRupert::Providers.for_turn(unconfigured, 'How do I clock in?').map(&:name)
  end

  test 'the panel says where words go' do
    assert_match(/cloud AI model/, AskRupert::Providers.disclosure(AskRupert::Config.new({})))
    assert_match(/stay on it/, AskRupert::Providers.disclosure(AskRupert::Config.new('provider_mode' => 'local_only')))
  end

  test 'ollama streams text and reports tokens' do
    ENV['OLLAMA_URL'] = 'http://ollama.test:11434'
    ENV['ASK_RUPERT_LOCAL_MODEL'] = 'gemma4:e4b'
    body = [{ message: { content: 'Open ' } }, { message: { content: 'Sync.' } }, { done: true, prompt_eval_count: 42, eval_count: 7 }].map { |line| "#{JSON.generate(line)}\n" }.join
    request = stub_request(:post, 'http://ollama.test:11434/api/chat').with { |req| JSON.parse(req.body)['model'] == 'gemma4:e4b' }.to_return(status: 200, body: body)
    seen = []
    reply = AskRupert::Providers::Ollama.new(AskRupert::Config.new({})).complete(system: 's', messages: [{ role: 'user', content: 'hi' }]) { |text| seen << text }
    assert_requested request
    assert_equal 'Open Sync.', reply.text
    assert_equal [42, 7], [reply.tokens_in, reply.tokens_out]
    assert_equal 'Open Sync.', seen.last
  end

  test 'ollama failures become provider errors with a kind' do
    ENV['OLLAMA_URL'] = 'http://ollama.test:11434'
    ENV['ASK_RUPERT_LOCAL_MODEL'] = 'gemma4:e4b'
    stub_request(:post, 'http://ollama.test:11434/api/chat').to_return(status: 503)
    error = assert_raises(AskRupert::ProviderError) { AskRupert::Providers::Ollama.new(AskRupert::Config.new({})).complete(system: 's', messages: []) }
    assert_equal :unavailable, error.kind
    stub_request(:post, 'http://ollama.test:11434/api/chat').to_timeout
    assert_equal :timeout, assert_raises(AskRupert::ProviderError) { AskRupert::Providers::Ollama.new(AskRupert::Config.new({})).complete(system: 's', messages: []) }.kind
  end

  test 'an unconfigured local model is unavailable, not a crash' do
    error = assert_raises(AskRupert::ProviderError) { AskRupert::Providers::Ollama.new(AskRupert::Config.new({})).complete(system: 's', messages: []) }
    assert_equal :unavailable, error.kind
  end

  test 'silent opencode output obeys deadlines and cancellation before a newline' do
    reader, writer = IO.pipe
    provider = AskRupert::Providers::Opencode.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(AskRupert::ProviderError) do
      provider.send(:lines, reader, started: started, deadline: 1.second.ago, checkpoint: nil) { flunk 'unexpected output' }
    end
    assert_equal :timeout, error.kind
    assert_raises(TeamChat::Run::Stopped) do
      provider.send(:lines, reader, started: started, deadline: 1.minute.from_now, checkpoint: -> { raise TeamChat::Run::Stopped }) { flunk 'unexpected output' }
    end
  ensure
    reader&.close
    writer&.close
  end

  test 'opencode reads the CLI json stream for text and tokens, with tools off' do
    Dir.mktmpdir do |dir|
      script = File.join(dir, 'opencode')
      File.write(script, <<~SH)
        #!/bin/sh
        echo "$@" > #{dir}/args
        echo '{"type":"text","part":{"type":"text","text":"Open Sync."}}'
        echo '{"type":"step_finish","part":{"tokens":{"input":30,"output":5,"reasoning":2,"cache":{"read":10,"write":0}}}}'
      SH
      File.chmod(0o755, script)
      ENV['ASK_RUPERT_OPENCODE_BIN'] = script
      reply = AskRupert::Providers::Opencode.new.complete(system: 'sys', messages: [{ role: 'user', content: 'where is sync' }])
      assert_equal 'Open Sync.', reply.text
      assert_equal [40, 7], [reply.tokens_in, reply.tokens_out]
      args = File.read(File.join(dir, 'args'))
      assert_match(/--agent chat/, args)
      assert_match(/--standalone/, args)
      refute_match(/--pure|--dir/, args)
    end
  end

  test 'opencode reports a rate limit and a missing binary as such' do
    Dir.mktmpdir do |dir|
      script = File.join(dir, 'opencode')
      File.write(script, "#!/bin/sh\necho 'Error: free usage limit reached (429)'\n")
      File.chmod(0o755, script)
      ENV['ASK_RUPERT_OPENCODE_BIN'] = script
      assert_equal :rate_limited, assert_raises(AskRupert::ProviderError) { AskRupert::Providers::Opencode.new.complete(system: 's', messages: []) }.kind
      ENV['ASK_RUPERT_OPENCODE_BIN'] = File.join(dir, 'missing')
      assert_equal :unavailable, assert_raises(AskRupert::ProviderError) { AskRupert::Providers::Opencode.new.complete(system: 's', messages: []) }.kind
    end
  end
end
