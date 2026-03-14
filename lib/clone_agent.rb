require_relative '../tools'
require_relative 'gruv_agent'

# CloneAgent is a restricted variant of GruvAgent used for background clone tasks.
# Results are reported back to the main gruv via the inbox, not via send tools.
class CloneAgent < GruvAgent
  # Excluded from clones:
  #   - SpawnCloneTaskTool  prevents recursive clone spawning
  #   - SendMessageTool     clones must not send messages directly to users
  #   - SendPhotoTool       same reason
  #   - SendVoiceTool       same reason
  #   - SendDocumentTool    same reason
  EXCLUDED_TOOLS = [
    SpawnCloneTaskTool,
    SendMessageTool,
    SendPhotoTool,
    SendVoiceTool,
    SendDocumentTool,
  ].freeze

  TOOLS = (GruvAgent::TOOLS - EXCLUDED_TOOLS).freeze
end
