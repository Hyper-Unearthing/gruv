#!/usr/bin/env ruby

require 'optparse'
require 'securerandom'
require 'json'
require 'llm_gateway'
require 'singleton'
require_relative 'lib/agent'
require_relative 'lib/prompt'
require_relative 'lib/logging'
require_relative 'lib/openai_oauth'
require_relative 'lib/anthropic_oauth'
require_relative 'lib/instance_file_scope'
require_relative 'modes/interactive'
require_relative 'modes/message'
require_relative 'lib/sessions/file_session_manager'
require_relative 'lib/agent_session'
# Enable immediate output flushing for real-time streaming
$stdout.sync = true


# Simple runner that takes auth and message arguments
class AgentRunner
  PROVIDERS_FILE = InstanceFileScope.path('providers.json')

  def initialize
    @options = {
      model: nil,
      provider: nil,
      message: nil,
      session_file: nil
    }
  end

  def parse_args
    OptionParser.new do |opts|
      opts.banner = 'Usage: run_agent.rb [options]'

      opts.on('-m MESSAGE', '--message MESSAGE', 'The prompt/message for the agent') do |m|
        @options[:message] = m
      end

      opts.on('-p PROVIDER', '--provider PROVIDER', 'Provider key from providers.json (default: first entry)') do |p|
        @options[:provider] = p
      end

      opts.on('--model MODEL', 'Model name') do |model|
        @options[:model] = model
      end

      opts.on('-s FILE', '--session FILE', 'Load an existing session file') do |file|
        @options[:session_file] = file
      end

      opts.on('-h', '--help', 'Prints this help') do
        puts opts
        exit
      end
    end.parse!
  end

  def run
    parse_args
    unless File.exist?(PROVIDERS_FILE)
      puts "No providers.json found at #{PROVIDERS_FILE}. Run 'ruby setup_provider.rb <provider>' first."
      exit 1
    end

    providers = JSON.parse(File.read(PROVIDERS_FILE))
    name = @options[:provider] || providers.keys.first
    provider_config = providers[name]

    unless provider_config
      puts "Provider '#{name}' not found in providers.json"
      puts "Available: #{providers.keys.join(', ')}"
      exit 1
    end

    model = @options[:model] || provider_config['model_key']

    configured_entries = providers.map do |provider_name, config|
      resolved_config = config.merge('provider' => provider_name)
      resolved_config['model_key'] = @options[:model] if @options[:model] && provider_name == name
      { name: provider_name, config: resolved_config }
    end

    LlmGateway.reset_configuration!
    LlmGateway.configure(configured_entries)
    client = LlmGateway.configured_clients[name.to_sym]

    unless client
      puts "Configured client '#{name}' not found"
      puts "Available configured clients: #{LlmGateway.configured_clients.keys.join(', ')}"
      exit 1
    end

    @agent = Agent.new(Prompt, model, client)
    agent_session = AgentSession.new @agent, FileSessionManager.new(@options[:session_file])


    if @options[:message]
      message_mode = MessageMode.new(agent_session, @options[:message])
      message_mode.run
    else
      runner = InteractiveRunner.new(agent_session)
      runner.run
    end
  end

end

# Run if executed directly (expand paths for bundler compatibility)
if File.expand_path(__FILE__) == File.expand_path($PROGRAM_NAME)
  runner = AgentRunner.new
  runner.run
end
