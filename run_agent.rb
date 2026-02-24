#!/usr/bin/env ruby

require 'optparse'
require 'securerandom'
require 'json'
require 'llm_gateway'
require 'singleton'
require_relative 'lib/agent'
require_relative 'lib/prompt'
require_relative 'lib/events'
require_relative 'lib/openai_oauth'
require_relative 'lib/format_stream'
require_relative 'modes/interactive'
require_relative 'lib/sessions/file_session_manager'

# Enable immediate output flushing for real-time streaming
$stdout.sync = true


# Simple runner that takes auth and message arguments
class AgentRunner
  PROVIDERS_FILE = File.join(__dir__, 'providers.json')

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
    formatter = Formatter.new
    Events.instance.attach(formatter)

    parse_args

    unless File.exist?(PROVIDERS_FILE)
      puts "No providers.json found. Run 'ruby setup_provider.rb <provider>' first."
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

    config = provider_config.merge('provider' => name)
    config['model_key'] = @options[:model] if @options[:model]
    model = config['model_key']

    session_manager = begin
      if @options[:session_file]
        FileSessionManager.load_session(@options[:session_file])
      else
        FileSessionManager.new
      end
    rescue StandardError => e
      puts "Failed to load session '#{@options[:session_file]}': #{e.message}"
      exit 1
    end

    client = LlmGateway.build_provider(config)
    @agent = Agent.new(Prompt, model, client)
    @agent.subscribe(formatter)
    @agent.subscribe(session_manager)
    @agent.transcript = session_manager.current_transcript || []
    if @options[:message]
      # Single message mode
      @agent.run(@options[:message])
    else
      runner = InteractiveRunner.new(@agent, formatter, session_manager)
      runner.run
    end
  end

end

# Run if executed directly (expand paths for bundler compatibility)
if File.expand_path(__FILE__) == File.expand_path($PROGRAM_NAME)
  runner = AgentRunner.new
  runner.run
end
