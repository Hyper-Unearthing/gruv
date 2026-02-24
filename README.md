# Purpose 
Just an exploration of building my own agent

# Running

```
git clone git@github.com:Hyper-Unearthing/rubister.git
cd rubister
```

Using OpenAI plan
```bash
bundle exec ruby setup_provider.rb openai
bundle exec ruby ./run_agent.rb -p openai_oauth_responses
```
Using Anthropic plan
```bash
bundle exec ruby setup_provider.rb anthropic
bundle exec ruby ./run_agent.rb -p anthropic_oauth_messages
```

You can set up multiple providers — they'll all be stored in `providers.json`. not sure which will be called by default if you do, but you can always use -p to specify which one

```bash
  # Single message mode
  bundle exec ruby ./run_agent.rb -m "whats this app" 
```

```bash
  # Single message mode
  bundle exec ruby ./run_agent.rb -m "whats this app" 
```

```bash
  # resume, you can resume in -m or interactive mode
  bundle exec ruby ./run_agent.rb -s sessions/20260224_164714_1846b412-9260-4e18-aa96-c1b67eb93581.jsonl
```

## Building a Standalone Bundle

Create a distributable version that doesn't require `bundle install`:

```bash
# 1. Install dependencies in standalone mode
bundle install --standalone

# 2. Test the standalone version
./rubister --help

# 3. Package for distribution
./package.sh 1.0.0

# This creates a .tar.gz file with everything bundled
```

Users can then:
```bash
# Extract
tar -xzf rubister-1.0.0-darwin-arm64.tar.gz
rubister-1.0.0-darwin-arm64/rubister --model "claude_code/claude-sonnet-4-5" -m "Hello" | rubister-1.0.0-darwin-arm64/format_output.rb
```

## Distribution

The standalone bundle includes:
- All Ruby dependencies (in `bundle/` directory)
- Application code
- Wrapper script (`rubister`)
- No need for users to run `bundle install`

**Requirements for end users:**
- Ruby 2.7 or higher
