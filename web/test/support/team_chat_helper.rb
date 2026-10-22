# frozen_string_literal: true

require 'json'

# Fakes an OpenAI-compatible /chat/completions endpoint (what RubyLLM talks to
# for OpenCode Go and Ollama) with scripted streamed turns.
module TeamChatHelper
  LLM_BASE = 'https://llm.test/v1'

  def team_chat_config(env = {})
    TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'openai', 'RUPERT_CHAT_API_BASE' => LLM_BASE,
                                'RUPERT_CHAT_MODEL' => 'test-model', 'RUPERT_CHAT_API_KEY' => 'test-key' }.merge(env))
  end

  # Each turn is { text: '...' } or { tool: 'name', arguments: {...} }.
  def script_model(*turns)
    requests = []
    responses = turns.map { |turn| { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(turn) } }
    stub_request(:post, "#{LLM_BASE}/chat/completions").with { |request| requests << JSON.parse(request.body) }.to_return(*responses)
    stub_request(:get, "#{LLM_BASE}/health").to_return(body: { loaded: nil, last_load: @gateway_last_load }.to_json)
    requests
  end

  def sse_for(turn)
    chunks =
      if turn[:tool]
        [{ choices: [{ index: 0, delta: { role: 'assistant', content: nil, tool_calls: [
          { index: 0, id: "call_#{turn[:tool]}", type: 'function', function: { name: turn[:tool], arguments: JSON.generate(turn[:arguments] || {}) } }
        ] }, finish_reason: nil }] },
         { choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 50, completion_tokens: 5 } }]
      else
        words = turn[:text].scan(/\S+\s*/)
        words.map { |word| { choices: [{ index: 0, delta: { content: word }, finish_reason: nil }] } } +
          [{ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 60, completion_tokens: 12 } }]
      end
    chunks.map { |chunk| "data: #{JSON.generate({ id: 'x', object: 'chat.completion.chunk', model: 'test-model' }.merge(chunk))}\n\n" }.join + "data: [DONE]\n\n"
  end
end
