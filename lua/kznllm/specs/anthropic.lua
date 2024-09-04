local kznllm = require 'kznllm'
local Path = require 'plenary.path'

local M = {}

local API_KEY_NAME = 'ANTHROPIC_API_KEY'
local URL = 'https://api.anthropic.com/v1/messages'

local TEMPLATE_PATH = vim.fn.expand(vim.fn.stdpath 'data') .. '/lazy/kznllm.nvim'

M.MODELS = {
  { name = 'claude-3-5-sonnet-20240620', max_tokens = 8192 },
  { name = 'claude-3-opus-20240229', max_tokens = 4096 },
  { name = 'claude-3-haiku-20240307', max_tokens = 4096 },
}

M.SELECTED_MODEL_IDX = 1

M.MESSAGE_TEMPLATES = {

  --- this prompt has to be written to output valid code
  FILL_MODE_SYSTEM_PROMPT = 'anthropic/fill_mode_system_prompt.xml.jinja',
  FILL_MODE_USER_PROMPT = 'anthropic/fill_mode_user_prompt.xml.jinja',
}

local API_ERROR_MESSAGE = [[
ERROR: anthropic api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local Job = require 'plenary.job'
local current_event_state = nil

--- Constructs arguments for constructing an HTTP request to the OpenAI API
--- using cURL.
---
---@param data table
---@return string[]
function M.make_curl_args(data, opts)
  local url = opts and opts.url or URL
  local api_key = os.getenv(opts and opts.api_key_name or API_KEY_NAME)

  if not api_key then
    error(API_ERROR_MESSAGE:format(API_KEY_NAME, API_KEY_NAME), 1)
  end

  local args = {
    '-s', --silent
    '-N', --no buffer
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
    '-d',
    vim.json.encode(data),
    '-H',
    'x-api-key: ' .. api_key,
    '-H',
    'anthropic-version: 2023-06-01',
    '-H',
    'anthropic-beta: max-tokens-3-5-sonnet-2024-07-15',
    url,
  }

  return args
end

--- Anthropic SSE Specification
--- [See Documentation](https://docs.anthropic.com/en/api/messages-streaming#event-types)
---
--- Each server-sent event includes a named event type and associated JSON
--- data. Each event will use an SSE event name (e.g. event: message_stop),
--- and include the matching event type in its data.
---
--- Each stream uses the following event flow:
---
--- 1. `message_start`: contains a Message object with empty content.
---
--- 2. A series of content blocks, each of which have a `content_block_start`,
---    one or more `content_block_delta` events, and a `content_block_stop`
---    event. Each content block will have an index that corresponds to its
---    index in the final Message content array.
---
--- 3. One or more `message_delta` events, indicating top-level changes to the
---    final Message object.
--- 4. `message_stop` event
---
--- event types: `[message_start, content_block_start, content_block_delta, content_block_stop, message_delta, message_stop, error]`
---@param data string
---@return string
local function handle_data(data)
  local content = ''
  if data then
    local json = vim.json.decode(data)

    if json.delta and json.delta.text then
      content = json.delta.text
    end
  end

  return content
end

function M.make_job(args, writer_fn, on_exit_fn)
  local active_job = Job:new {
    command = 'curl',
    args = args,
    on_stdout = function(_, out)
      if out == '' then
        return
      end

      -- based on sse spec (Anthropic spec has several distinct events)
      -- Anthropic's sse spec requires you to manage the current event state
      local _, event_epos = string.find(out, '^event: ')

      if event_epos then
        current_event_state = string.sub(out, event_epos + 1)
        return
      end

      if current_event_state == 'content_block_delta' then
        local data, data_epos
        _, data_epos = string.find(out, '^data: ')

        if data_epos then
          data = string.sub(out, data_epos + 1)
        end

        local content = handle_data(data)
        if content and content ~= nil then
          vim.schedule(function()
            writer_fn(content)
          end)
        end
      elseif current_event_state == 'message_start' then
        local data, data_epos
        _, data_epos = string.find(out, '^data: ')

        if data_epos then
          data = string.sub(out, data_epos + 1)
        end

        vim.print(data)
      elseif current_event_state == 'message_delta' then
        local data, data_epos
        _, data_epos = string.find(out, '^data: ')

        if data_epos then
          data = string.sub(out, data_epos + 1)
        end

        vim.print(data)
      end
    end,
    on_stderr = function(message, _)
      error(message, 1)
    end,
    on_exit = function()
      vim.schedule(function()
        on_exit_fn()
      end)
    end,
  }
  return active_job
end

---Example implementation of a `make_data_fn` compatible with `kznllm.invoke_llm` for anthropic spec
---@param prompt_args any
---@param opts any
---@return table
function M.make_data_for_chat(prompt_args, opts)
  local template_path = Path:new(opts and opts.template_path or TEMPLATE_PATH)

  local messages = {
    {
      role = 'user',
      content = kznllm.make_prompt_from_template(template_path / M.MESSAGE_TEMPLATES.FILL_MODE_USER_PROMPT, prompt_args),
    },
  }

  local data = {
    system = kznllm.make_prompt_from_template(template_path / M.MESSAGE_TEMPLATES.FILL_MODE_SYSTEM_PROMPT, prompt_args),
    messages = messages,
    model = M.MODELS[M.SELECTED_MODEL_IDX].name,
    temperature = 0.7,
    stream = true,
    max_tokens = M.MODELS[M.SELECTED_MODEL_IDX].max_tokens,
  }

  if opts and opts.debug then
    local extmark_id = vim.api.nvim_buf_set_extmark(kznllm.BUFFER_STATE.SCRATCH, kznllm.NS_ID, 0, 0, {})
    kznllm.write_content_at_extmark('model: ' .. M.MODELS[M.SELECTED_MODEL_IDX].name, extmark_id)
    kznllm.write_content_at_extmark('\n\n---\n\n', extmark_id)

    kznllm.write_content_at_extmark('system' .. ':\n\n', extmark_id)
    kznllm.write_content_at_extmark(data.system, extmark_id)
    kznllm.write_content_at_extmark('\n\n---\n\n', extmark_id)
    for _, message in ipairs(data.messages) do
      kznllm.write_content_at_extmark(message.role .. ':\n\n', extmark_id)
      kznllm.write_content_at_extmark(message.content, extmark_id)
      kznllm.write_content_at_extmark('\n\n---\n\n', extmark_id)
      vim.cmd 'normal! G'
    end
  end

  return data
end

return M
