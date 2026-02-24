#!/usr/bin/env ruby

require 'json'
require 'fileutils'
require 'llm_gateway'
require_relative 'lib/openai_oauth'
require_relative 'lib/instance_file_scope'

PROVIDERS_FILE = InstanceFileScope.path('providers.json')

SUPPORTED_PROVIDERS = {
  'anthropic' => {
    registry_key: 'anthropic_oauth_messages',
    default_model: 'claude_code/claude-sonnet-4-5'
  },
  'openai' => {
    registry_key: 'openai_oauth_responses',
    default_model: 'gpt-5.1-codex-mini'
  }
}.freeze

def run_oauth_flow(provider)
  case provider
  when 'anthropic'
    flow = LlmGateway::Clients::ClaudeCode::OAuthFlow.new
    result = flow.start
    puts "Open this URL to authorize:"
    puts result[:authorization_url]
    puts
    print "Paste the code (format: code#state): "

    tty = File.open('/dev/tty', 'r')
    auth_code = tty.gets&.strip
    tty.close

    if auth_code.nil? || auth_code.empty?
      puts "Error: No authorization code provided"
      exit 1
    end

    flow.exchange_code(auth_code, result[:code_verifier])
  when 'openai'
    OpenAiOAuth.login
  end
end

def save_provider(registry_key, model_key, tokens)
  providers = if File.exist?(PROVIDERS_FILE)
    JSON.parse(File.read(PROVIDERS_FILE))
  else
    {}
  end

  entry = {
    'model_key' => model_key,
    'access_token' => tokens[:access_token],
    'refresh_token' => tokens[:refresh_token],
    'expires_at' => tokens[:expires_at]&.to_i
  }
  entry['account_id'] = tokens[:account_id] if tokens[:account_id]

  providers[registry_key] = entry

  File.write(PROVIDERS_FILE, JSON.pretty_generate(providers))
end

provider = ARGV[0]

unless SUPPORTED_PROVIDERS.key?(provider)
  puts "Usage: ruby setup_provider.rb <provider>"
  puts "Supported providers: #{SUPPORTED_PROVIDERS.keys.join(', ')}"
  exit 1
end

config = SUPPORTED_PROVIDERS[provider]
tokens = run_oauth_flow(provider)
save_provider(config[:registry_key], config[:default_model], tokens)

puts "Provider '#{config[:registry_key]}' saved to #{PROVIDERS_FILE}"
