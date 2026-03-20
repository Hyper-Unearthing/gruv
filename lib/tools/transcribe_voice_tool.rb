# frozen_string_literal: true

require 'json'
require_relative '../app_config'
require_relative '../clients/assemblyai_client'

class TranscribeVoiceTool < LlmGateway::Tool
  name 'transcribe_voice'
  description 'Transcribe audio/voice files to text using AssemblyAI. Supports various audio formats (mp3, wav, m4a, ogg, etc.). Provide a local file path or URL to audio file.'
  input_schema({
    type: 'object',
    properties: {
      audio_url: {
        type: 'string',
        description: 'URL to audio file or local file path to transcribe'
      },
      language_code: {
        type: 'string',
        description: 'Optional language code (e.g., "en", "es", "fr"). Defaults to automatic detection.'
      },
      speaker_labels: {
        type: 'boolean',
        description: 'Enable speaker diarization to identify different speakers. Default: false'
      },
      auto_highlights: {
        type: 'boolean',
        description: 'Extract key phrases and important highlights. Default: false'
      }
    },
    required: ['audio_url']
  })

  def execute(input)
    api_key = get_api_key
    return error_response('AssemblyAI API key not configured. Run ./scripts/setup_assemblyai.rb or add "assemblyai_api_key" to config.json') unless api_key

    # Create client
    client = AssemblyAIClient.new(api_key)

    # Prepare options
    options = {}
    options[:language_code] = input[:language_code] if input[:language_code]
    options[:speaker_labels] = input[:speaker_labels] if input[:speaker_labels]
    options[:auto_highlights] = input[:auto_highlights] if input[:auto_highlights]

    # Transcribe
    result = client.transcribe(input[:audio_url], options)
    
    format_response(result)
  rescue AssemblyAIClient::Error => e
    error_response(e.message)
  rescue StandardError => e
    error_response("Transcription failed: #{e.message}")
  end

  private

  def get_api_key
    config = AppConfig.load
    config['assemblyai_api_key']
  end

  def format_response(result)
    response = {
      text: result['text'],
      confidence: result['confidence'],
      duration: result['audio_duration'],
      words_count: result['words']&.length || 0
    }
    
    # Add speaker labels if available
    if result['utterances']
      response[:speakers] = result['utterances'].map do |utterance|
        {
          speaker: utterance['speaker'],
          text: utterance['text'],
          confidence: utterance['confidence'],
          start: utterance['start'],
          end: utterance['end']
        }
      end
    end
    
    # Add highlights if available
    if result['auto_highlights_result']
      response[:highlights] = result['auto_highlights_result']['results']&.map do |h|
        {
          text: h['text'],
          count: h['count'],
          rank: h['rank']
        }
      end
    end
    
    JSON.generate(response, pretty: true)
  end

  def error_response(message)
    JSON.generate({ error: message })
  end
end
